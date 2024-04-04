// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.16;

import { MultiToken, IMultiTokenCategoryRegistry } from "MultiToken/MultiToken.sol";

import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import { PWNConfig } from "@pwn/config/PWNConfig.sol";
import { PWNHub } from "@pwn/hub/PWNHub.sol";
import { PWNHubTags } from "@pwn/hub/PWNHubTags.sol";
import { PWNFeeCalculator } from "@pwn/loan/lib/PWNFeeCalculator.sol";
import { PWNSignatureChecker } from "@pwn/loan/lib/PWNSignatureChecker.sol";
import { PWNSimpleLoanProposal } from "@pwn/loan/terms/simple/proposal/PWNSimpleLoanProposal.sol";
import { IERC5646 } from "@pwn/loan/token/IERC5646.sol";
import { IPWNLoanMetadataProvider } from "@pwn/loan/token/IPWNLoanMetadataProvider.sol";
import { PWNLOAN } from "@pwn/loan/token/PWNLOAN.sol";
import { Permit } from "@pwn/loan/vault/Permit.sol";
import { PWNVault } from "@pwn/loan/vault/PWNVault.sol";
import { PWNRevokedNonce } from "@pwn/nonce/PWNRevokedNonce.sol";
import "@pwn/PWNErrors.sol";


/**
 * @title PWN Simple Loan
 * @notice Contract managing a simple loan in PWN protocol.
 * @dev Acts as a vault for every loan created by this contract.
 */
contract PWNSimpleLoan is PWNVault, IERC5646, IPWNLoanMetadataProvider {
    using MultiToken for address;

    string public constant VERSION = "1.2";

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    uint32 public constant MIN_LOAN_DURATION = 10 minutes;
    uint40 public constant MAX_ACCRUING_INTEREST_APR = 1e11; // 1,000,000% APR

    uint256 public constant APR_INTEREST_DENOMINATOR = 1e4;
    uint256 public constant DAILY_INTEREST_DENOMINATOR = 1e10;

    uint256 public constant APR_TO_DAILY_INTEREST_NUMERATOR = 274;
    uint256 public constant APR_TO_DAILY_INTEREST_DENOMINATOR = 1e5;

    uint256 public constant MAX_EXTENSION_DURATION = 90 days;
    uint256 public constant MIN_EXTENSION_DURATION = 1 days;

    bytes32 public constant EXTENSION_PROPOSAL_TYPEHASH = keccak256(
        "ExtensionProposal(uint256 loanId,address compensationAddress,uint256 compensationAmount,uint40 duration,uint40 expiration,address proposer,uint256 nonceSpace,uint256 nonce)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR = keccak256(abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("PWNSimpleLoan"),
        keccak256(abi.encodePacked(VERSION)),
        block.chainid,
        address(this)
    ));

    PWNHub public immutable hub;
    PWNLOAN public immutable loanToken;
    PWNConfig public immutable config;
    PWNRevokedNonce public immutable revokedNonce;
    IMultiTokenCategoryRegistry public immutable categoryRegistry;

    /**
     * @notice Struct defining a simple loan terms.
     * @dev This struct is created by proposal contracts and never stored.
     * @param lender Address of a lender.
     * @param borrower Address of a borrower.
     * @param duration Loan duration in seconds.
     * @param collateral Asset used as a loan collateral. For a definition see { MultiToken dependency lib }.
     * @param credit Asset used as a loan credit. For a definition see { MultiToken dependency lib }.
     * @param fixedInterestAmount Fixed interest amount in credit asset tokens. It is the minimum amount of interest which has to be paid by a borrower.
     * @param accruingInterestAPR Accruing interest APR.
     * @param lenderSpecHash Hash of a lender specification.
     * @param borrowerSpecHash Hash of a borrower specification.
     */
    struct Terms {
        address lender;
        address borrower;
        uint32 duration;
        MultiToken.Asset collateral;
        MultiToken.Asset credit;
        uint256 fixedInterestAmount;
        uint40 accruingInterestAPR;
        bytes32 lenderSpecHash;
        bytes32 borrowerSpecHash;
    }

    /**
     * @notice Loan proposal specification during loan creation.
     * @param proposalContract Address of a loan proposal contract.
     * @param proposalData Encoded proposal data that is passed to the loan proposal contract.
     * @param signature Signature of the proposal.
     */
    struct ProposalSpec {
        address proposalContract;
        bytes proposalData;
        bytes signature;
    }

    /**
     * @notice Lender specification during loan creation.
     * @param sourceOfFunds Address of a source of funds. This address can be an address of a Compound v3 pool or
     *                      lender address if lender is funding the loan directly.
     */
    struct LenderSpec {
        address sourceOfFunds;
    }

    /**
     * @notice Caller specification during loan creation.
     * @param refinancingLoanId Id of a loan to be refinanced. 0 if creating a new loan.
     * @param revokeNonce Flag if the callers nonce should be revoked.
     * @param nonce Callers nonce to be revoked. Nonce is revoked from the current nonce space.
     * @param permit Callers permit data for a loans credit asset.
     */
    struct CallerSpec {
        uint256 refinancingLoanId;
        bool revokeNonce;
        uint256 nonce;
        Permit permit;
    }

    /**
     * @notice Struct defining a simple loan.
     * @param status 0 == none/dead || 2 == running/accepted offer/accepted request || 3 == paid back || 4 == expired.
     * @param creditAddress Address of an asset used as a loan credit.
     * @param originalSourceOfFunds Address of a source of funds that was used to fund the loan.
     * @param startTimestamp Unix timestamp (in seconds) of a start date.
     * @param defaultTimestamp Unix timestamp (in seconds) of a default date.
     * @param borrower Address of a borrower.
     * @param originalLender Address of a lender that funded the loan.
     * @param accruingInterestDailyRate Accruing daily interest rate.
     * @param fixedInterestAmount Fixed interest amount in credit asset tokens.
     *                            It is the minimum amount of interest which has to be paid by a borrower.
     *                            This property is reused to store the final interest amount if the loan is repaid and waiting to be claimed.
     * @param principalAmount Principal amount in credit asset tokens.
     * @param collateral Asset used as a loan collateral. For a definition see { MultiToken dependency lib }.
     */
    struct LOAN {
        uint8 status;
        address creditAddress;
        address originalSourceOfFunds;
        uint40 startTimestamp;
        uint40 defaultTimestamp;
        address borrower;
        address originalLender;
        uint40 accruingInterestDailyRate;
        uint256 fixedInterestAmount;
        uint256 principalAmount;
        MultiToken.Asset collateral;
    }

    /**
     * Mapping of all LOAN data by loan id.
     */
    mapping (uint256 => LOAN) private LOANs;

    /**
     * @notice Struct defining a loan extension proposal that can be signed by a borrower or a lender.
     * @param loanId Id of a loan to be extended.
     * @param compensationAddress Address of a compensation asset.
     * @param compensationAmount Amount of a compensation asset that a borrower has to pay to a lender.
     * @param duration Duration of the extension in seconds.
     * @param expiration Unix timestamp (in seconds) of an expiration date.
     * @param proposer Address of a proposer that signed the extension proposal.
     * @param nonceSpace Nonce space of the extension proposal nonce.
     * @param nonce Nonce of the extension proposal.
     */
    struct ExtensionProposal {
        uint256 loanId;
        address compensationAddress;
        uint256 compensationAmount;
        uint40 duration;
        uint40 expiration;
        address proposer;
        uint256 nonceSpace;
        uint256 nonce;
    }

    /**
     * Mapping of extension proposals made via on-chain transaction by extension hash.
     */
    mapping (bytes32 => bool) public extensionProposalsMade;


    /*----------------------------------------------------------*|
    |*  # EVENTS & ERRORS DEFINITIONS                           *|
    |*----------------------------------------------------------*/

    /**
     * @dev Emitted when a new loan in created.
     */
    event LOANCreated(uint256 indexed loanId, bytes32 indexed proposalHash, address indexed proposalContract, Terms terms, LenderSpec lenderSpec, bytes extra);

    /**
     * @dev Emitted when a loan is refinanced.
     */
    event LOANRefinanced(uint256 indexed loanId, uint256 indexed refinancedLoanId);

    /**
     * @dev Emitted when a loan is paid back.
     */
    event LOANPaidBack(uint256 indexed loanId);

    /**
     * @dev Emitted when a repaid or defaulted loan is claimed.
     */
    event LOANClaimed(uint256 indexed loanId, bool indexed defaulted);

    /**
     * @dev Emitted when a LOAN token holder extends a loan.
     */
    event LOANExtended(uint256 indexed loanId, uint40 originalDefaultTimestamp, uint40 extendedDefaultTimestamp);

    /**
     * @dev Emitted when a loan extension proposal is made.
     */
    event ExtensionProposalMade(bytes32 indexed extensionHash, address indexed proposer,  ExtensionProposal proposal);


    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR                                           *|
    |*----------------------------------------------------------*/

    constructor(
        address _hub,
        address _loanToken,
        address _config,
        address _revokedNonce,
        address _categoryRegistry
    ) {
        hub = PWNHub(_hub);
        loanToken = PWNLOAN(_loanToken);
        config = PWNConfig(_config);
        revokedNonce = PWNRevokedNonce(_revokedNonce);
        categoryRegistry = IMultiTokenCategoryRegistry(_categoryRegistry);
    }


    /*----------------------------------------------------------*|
    |*  # LENDER SPEC                                           *|
    |*----------------------------------------------------------*/

    /**
     * @notice Get hash of a lender specification.
     * @param lenderSpec Lender specification struct.
     * @return Hash of a lender specification.
     */
    function getLenderSpecHash(LenderSpec calldata lenderSpec) public pure returns (bytes32) {
        return keccak256(abi.encode(lenderSpec));
    }


    /*----------------------------------------------------------*|
    |*  # CREATE LOAN                                           *|
    |*----------------------------------------------------------*/

    /**
     * @notice Create a new loan.
     * @dev The function assumes a prior token approval to a contract address or signed permits.
     * @param proposalSpec Proposal specification struct.
     * @param lenderSpec Lender specification struct.
     * @param callerSpec Caller specification struct.
     * @param extra Auxiliary data that are emitted in the loan creation event. They are not used in the contract logic.
     * @return loanId Id of the created LOAN token.
     */
    function createLOAN(
        ProposalSpec calldata proposalSpec,
        LenderSpec calldata lenderSpec,
        CallerSpec calldata callerSpec,
        bytes calldata extra
    ) external returns (uint256 loanId) {
        // Check provided proposal contract
        if (!hub.hasTag(proposalSpec.proposalContract, PWNHubTags.LOAN_PROPOSAL)) {
            revert AddressMissingHubTag({ addr: proposalSpec.proposalContract, tag: PWNHubTags.LOAN_PROPOSAL });
        }

        // Revoke nonce if needed
        if (callerSpec.revokeNonce) {
            revokedNonce.revokeNonce(msg.sender, callerSpec.nonce);
        }

        // If refinancing a loan, check that the loan can be repaid
        if (callerSpec.refinancingLoanId != 0) {
            LOAN storage loan = LOANs[callerSpec.refinancingLoanId];
            _checkLoanCanBeRepaid(loan.status, loan.defaultTimestamp);
        }

        // Accept proposal and get loan terms
        (bytes32 proposalHash, Terms memory loanTerms) = PWNSimpleLoanProposal(proposalSpec.proposalContract)
            .acceptProposal({
                acceptor: msg.sender,
                refinancingLoanId: callerSpec.refinancingLoanId,
                proposalData: proposalSpec.proposalData,
                signature: proposalSpec.signature
            });

        // Check that provided lender spec is correct
        if (msg.sender != loanTerms.lender && loanTerms.lenderSpecHash != getLenderSpecHash(lenderSpec)) {
            revert InvalidLenderSpecHash({ current: loanTerms.lenderSpecHash, expected: getLenderSpecHash(lenderSpec) });
        }
        // Check that the lender is the source of funds or the source of funds is a Compound pool
        if (lenderSpec.sourceOfFunds != loanTerms.lender) {
            if (!hub.hasTag(lenderSpec.sourceOfFunds, PWNHubTags.COMPOUND_V3_POOL)) {
                revert AddressMissingHubTag({ addr: lenderSpec.sourceOfFunds, tag: PWNHubTags.COMPOUND_V3_POOL });
            }
        }

        // Check minimum loan duration
        if (loanTerms.duration < MIN_LOAN_DURATION) {
            revert InvalidDuration({ current: loanTerms.duration, limit: MIN_LOAN_DURATION });
        }
        // Check maximum accruing interest APR
        if (loanTerms.accruingInterestAPR > MAX_ACCRUING_INTEREST_APR) {
            revert AccruingInterestAPROutOfBounds({ current: loanTerms.accruingInterestAPR, limit: MAX_ACCRUING_INTEREST_APR });
        }

        if (callerSpec.refinancingLoanId == 0) {
            // Check loan credit and collateral validity
            _checkValidAsset(loanTerms.credit);
            _checkValidAsset(loanTerms.collateral);
        } else {
            // Check refinance loan terms
            _checkRefinanceLoanTerms(callerSpec.refinancingLoanId, loanTerms);
        }

        // Create a new loan
        loanId = _createLoan({
            proposalHash: proposalHash,
            proposalContract: proposalSpec.proposalContract,
            loanTerms: loanTerms,
            lenderSpec: lenderSpec,
            extra: extra
        });

        // Execute permit for the caller
        _checkPermit(msg.sender, loanTerms.credit.assetAddress, callerSpec.permit);
        _tryPermit(callerSpec.permit);

        // Settle the loan
        if (callerSpec.refinancingLoanId == 0) {
            // Transfer collateral to Vault and credit to borrower
            _settleNewLoan(loanTerms, lenderSpec);
        } else {
            // Update loan to repaid state
            _updateRepaidLoan(callerSpec.refinancingLoanId);

            // Repay the original loan and transfer the surplus to the borrower if any
            _settleLoanRefinance({
                refinancingLoanId: callerSpec.refinancingLoanId,
                loanTerms: loanTerms,
                lenderSpec: lenderSpec
            });

            emit LOANRefinanced({ loanId: callerSpec.refinancingLoanId, refinancedLoanId: loanId });
        }
    }

    /**
     * @notice Check that permit data have correct owner and asset.
     * @param caller Caller address.
     * @param creditAddress Address of a credit to be used.
     * @param permit Permit to be checked.
     */
    function _checkPermit(address caller, address creditAddress, Permit calldata permit) private pure {
        if (permit.asset != address(0)) {
            if (permit.owner != caller) {
                revert InvalidPermitOwner({ current: permit.owner, expected: caller});
            }
            if (permit.asset != creditAddress) {
                revert InvalidPermitAsset({ current: permit.asset, expected: creditAddress });
            }
        }
    }

    /**
     * @notice Check if the loan terms are valid for refinancing.
     * @dev The function will revert if the loan terms are not valid for refinancing.
     * @param loanId Original loan id.
     * @param loanTerms Refinancing loan terms struct.
     */
    function _checkRefinanceLoanTerms(uint256 loanId, Terms memory loanTerms) private view {
        LOAN storage loan = LOANs[loanId];

        // Check that the credit asset is the same as in the original loan
        // Note: Address check is enough because the asset has always ERC20 category and zero id.
        // Amount can be different, but nonzero.
        if (
            loan.creditAddress != loanTerms.credit.assetAddress ||
            loanTerms.credit.amount == 0
        ) revert RefinanceCreditMismatch();

        // Check that the collateral is identical to the original one
        if (
            loan.collateral.category != loanTerms.collateral.category ||
            loan.collateral.assetAddress != loanTerms.collateral.assetAddress ||
            loan.collateral.id != loanTerms.collateral.id ||
            loan.collateral.amount != loanTerms.collateral.amount
        ) revert RefinanceCollateralMismatch();

        // Check that the borrower is the same as in the original loan
        if (loan.borrower != loanTerms.borrower) {
            revert RefinanceBorrowerMismatch({
                currentBorrower: loan.borrower,
                newBorrower: loanTerms.borrower
            });
        }
    }

    /**
     * @notice Mint LOAN token and store loan data under loan id.
     * @param proposalHash Hash of a loan offer / request that is signed by a lender / borrower.
     * @param proposalContract Address of a loan proposal contract.
     * @param loanTerms Loan terms struct.
     * @param extra Auxiliary data that are emitted in the loan creation event. They are not used in the contract logic.
     */
    function _createLoan(
        bytes32 proposalHash,
        address proposalContract,
        Terms memory loanTerms,
        LenderSpec calldata lenderSpec,
        bytes calldata extra
    ) private returns (uint256 loanId) {
        // Mint LOAN token for lender
        loanId = loanToken.mint(loanTerms.lender);

        // Store loan data under loan id
        LOAN storage loan = LOANs[loanId];
        loan.status = 2;
        loan.creditAddress = loanTerms.credit.assetAddress;
        loan.originalSourceOfFunds = lenderSpec.sourceOfFunds;
        loan.startTimestamp = uint40(block.timestamp);
        loan.defaultTimestamp = uint40(block.timestamp) + loanTerms.duration;
        loan.borrower = loanTerms.borrower;
        loan.originalLender = loanTerms.lender;
        loan.accruingInterestDailyRate = SafeCast.toUint40(Math.mulDiv(
            loanTerms.accruingInterestAPR, APR_TO_DAILY_INTEREST_NUMERATOR, APR_TO_DAILY_INTEREST_DENOMINATOR
        ));
        loan.fixedInterestAmount = loanTerms.fixedInterestAmount;
        loan.principalAmount = loanTerms.credit.amount;
        loan.collateral = loanTerms.collateral;

        emit LOANCreated({
            loanId: loanId,
            proposalHash: proposalHash,
            proposalContract: proposalContract,
            terms: loanTerms,
            lenderSpec: lenderSpec,
            extra: extra
        });
    }

    /**
     * @notice Transfer collateral to Vault and credit to borrower.
     * @dev The function assumes a prior token approval to a contract address or signed permits.
     * @param loanTerms Loan terms struct.
     */
    function _settleNewLoan(
        Terms memory loanTerms,
        LenderSpec calldata lenderSpec
    ) private {
        // Transfer collateral to Vault
        _pull(loanTerms.collateral, loanTerms.borrower);

        // Decide credit provider
        address creditProvider = loanTerms.lender;
        if (lenderSpec.sourceOfFunds != loanTerms.lender) {

            // Note: Lender is not source of funds.
            // Withdraw credit asset to the loan contract and use it as a credit provider.

            _withdrawFromCompound(loanTerms.credit, lenderSpec.sourceOfFunds, loanTerms.lender);
            creditProvider = address(this);
        }

        // Calculate fee amount and new loan amount
        (uint256 feeAmount, uint256 newLoanAmount)
            = PWNFeeCalculator.calculateFeeAmount(config.fee(), loanTerms.credit.amount);

        // Note: `creditHelper` must not be used before updating the amount.
        MultiToken.Asset memory creditHelper = loanTerms.credit;

        // Collect fees
        if (feeAmount > 0) {
            creditHelper.amount = feeAmount;
            _pushFrom(creditHelper, creditProvider, config.feeCollector());
        }

        // Transfer credit to borrower
        creditHelper.amount = newLoanAmount;
        _pushFrom(creditHelper, creditProvider, loanTerms.borrower);
    }

    /**
     * @notice Settle the refinanced loan. If the new lender is the same as the current LOAN owner,
     *         the function will transfer only the surplus to the borrower, if any.
     *         If the new loan amount is not enough to cover the original loan, the borrower needs to contribute.
     *         The function assumes a prior token approval to a contract address or signed permits.
     * @param refinancingLoanId Id of a loan to be refinanced.
     * @param loanTerms Loan terms struct.
     * @param lenderSpec Lender specification struct.
     */
    function _settleLoanRefinance(
        uint256 refinancingLoanId,
        Terms memory loanTerms,
        LenderSpec calldata lenderSpec
    ) private {
        LOAN storage loan = LOANs[refinancingLoanId];
        address loanOwner = loanToken.ownerOf(refinancingLoanId);
        uint256 repaymentAmount = _loanRepaymentAmount(refinancingLoanId);

        // Calculate fee amount and new loan amount
        (uint256 feeAmount, uint256 newLoanAmount)
            = PWNFeeCalculator.calculateFeeAmount(config.fee(), loanTerms.credit.amount);

        uint256 common = Math.min(repaymentAmount, newLoanAmount);
        uint256 surplus = newLoanAmount > repaymentAmount ? newLoanAmount - repaymentAmount : 0;
        uint256 shortage = surplus > 0 ? 0 : repaymentAmount - newLoanAmount;

        // Note: New lender will always transfer common loan amount to the Vault, except when:
        // - the new lender is the current loan owner but not the original lender
        // - the new lender is the current loan owner, is the original lender, and the new and original source of funds are equal

        bool shouldTransferCommon =
            loanTerms.lender != loanOwner ||
            (loan.originalLender == loanOwner && loan.originalSourceOfFunds != lenderSpec.sourceOfFunds);

        // Note: `creditHelper` must not be used before updating the amount.
        MultiToken.Asset memory creditHelper = loanTerms.credit;

        // Decide credit provider
        address creditProvider = loanTerms.lender;
        if (lenderSpec.sourceOfFunds != loanTerms.lender) {

            // Note: Lender is not the source of funds. Withdraw credit asset to the Vault and use it
            // as a credit provider to minimize the number of withdrawals.

            creditHelper.amount = feeAmount + (shouldTransferCommon ? common : 0) + surplus;
            if (creditHelper.amount > 0) {
                _withdrawFromCompound(creditHelper, lenderSpec.sourceOfFunds, loanTerms.lender);
            }
            creditProvider = address(this);
        }

        // Collect fees
        if (feeAmount > 0) {
            creditHelper.amount = feeAmount;
            _pushFrom(creditHelper, creditProvider, config.feeCollector());
        }

        // Transfer common amount to the Vault if necessary
        // Note: If the `creditProvider` is a vault, the common amount is already in the vault.
        if (shouldTransferCommon && creditProvider != address(this)) {
            creditHelper.amount = common;
            _pull(creditHelper, creditProvider);
        }

        // Handle the surplus or the shortage
        if (surplus > 0) {
            // New loan covers the whole original loan, transfer surplus to the borrower
            creditHelper.amount = surplus;
            _pushFrom(creditHelper, creditProvider, loanTerms.borrower);
        } else if (shortage > 0) {
            // New loan covers only part of the original loan, borrower needs to contribute
            creditHelper.amount = shortage;
            _pull(creditHelper, loanTerms.borrower);
        }

        try this.tryClaimRepaidLOANForLoanOwner(refinancingLoanId, loanOwner) {} catch {
            // Note: Safe transfer or supply to a pool can fail. In that case the LOAN token stays in repaid state and
            // waits for the LOAN token owner to claim the repaid credit. Otherwise lender would be able to prevent
            // anybody from repaying the loan.
        }
    }


    /*----------------------------------------------------------*|
    |*  # REPAY LOAN                                            *|
    |*----------------------------------------------------------*/

    /**
     * @notice Repay running loan.
     * @dev Any address can repay a running loan, but a collateral will be transferred to a borrower address associated with the loan.
     *      If the LOAN token holder is the same as the original lender, the repayment credit asset will be
     *      transferred to the LOAN token holder directly. Otherwise it will transfer the repayment credit asset to
     *      a vault, waiting on a LOAN token holder to claim it. The function assumes a prior token approval to a contract address
     *      or a signed permit.
     * @param loanId Id of a loan that is being repaid.
     * @param permit Callers credit permit data.
     */
    function repayLOAN(
        uint256 loanId,
        Permit calldata permit
    ) external {
        LOAN storage loan = LOANs[loanId];

        _checkLoanCanBeRepaid(loan.status, loan.defaultTimestamp);

        // Update loan to repaid state
        _updateRepaidLoan(loanId);

        // Execute permit for the caller
        _checkPermit(msg.sender, loan.creditAddress, permit);
        _tryPermit(permit);

        // Transfer the repaid credit to the Vault
        _pull(loan.creditAddress.ERC20(_loanRepaymentAmount(loanId)), msg.sender);

        // Transfer collateral back to borrower
        _push(loan.collateral, loan.borrower);

        // Try to repay directly
        try this.tryClaimRepaidLOANForLoanOwner(loanId, loanToken.ownerOf(loanId)) {} catch {
            // Note: Safe transfer or supply to a pool can fail. In that case leave the LOAN token in repaid state and
            // wait for the LOAN token owner to claim the repaid credit. Otherwise lender would be able to prevent
            // borrower from repaying the loan.
        }
    }

    /**
     * @notice Check if the loan can be repaid.
     * @dev The function will revert if the loan cannot be repaid.
     * @param status Loan status.
     * @param defaultTimestamp Loan default timestamp.
     */
    function _checkLoanCanBeRepaid(uint8 status, uint40 defaultTimestamp) private view {
        // Check that loan exists and is not from a different loan contract
        if (status == 0) revert NonExistingLoan();
        // Check that loan is running
        if (status != 2) revert InvalidLoanStatus(status);
        // Check that loan is not defaulted
        if (defaultTimestamp <= block.timestamp) revert LoanDefaulted(defaultTimestamp);
    }

    /**
     * @notice Update loan to repaid state.
     * @param loanId Id of a loan that is being repaid.
     */
    function _updateRepaidLoan(uint256 loanId) private {
        LOAN storage loan = LOANs[loanId];

        // Move loan to repaid state and wait for the loan owner to claim the repaid credit
        loan.status = 3;

        // Update accrued interest amount
        loan.fixedInterestAmount = _loanAccruedInterest(loan);
        loan.accruingInterestDailyRate = 0;

        // Note: Reusing `fixedInterestAmount` to store accrued interest at the time of repayment
        // to have the value at the time of claim and stop accruing new interest.

        emit LOANPaidBack({ loanId: loanId });
    }


    /*----------------------------------------------------------*|
    |*  # LOAN REPAYMENT AMOUNT                                 *|
    |*----------------------------------------------------------*/

    /**
     * @notice Calculate the loan repayment amount with fixed and accrued interest.
     * @param loanId Id of a loan.
     * @return Repayment amount.
     */
    function loanRepaymentAmount(uint256 loanId) public view returns (uint256) {
        LOAN storage loan = LOANs[loanId];

        // Check non-existent
        if (loan.status == 0) return 0;

        return _loanRepaymentAmount(loanId);
    }

    /**
     * @notice Internal function to calculate the loan repayment amount with fixed and accrued interest.
     * @param loanId Id of a loan.
     * @return Repayment amount.
     */
    function _loanRepaymentAmount(uint256 loanId) private view returns (uint256) {
        LOAN storage loan = LOANs[loanId];

        // Return loan principal with accrued interest
        return loan.principalAmount + _loanAccruedInterest(loan);
    }

    /**
     * @notice Calculate the loan accrued interest.
     * @param loan Loan data struct.
     * @return Accrued interest amount.
     */
    function _loanAccruedInterest(LOAN storage loan) private view returns (uint256) {
        if (loan.accruingInterestDailyRate == 0)
            return loan.fixedInterestAmount;

        uint256 accruingDays = (block.timestamp - loan.startTimestamp) / 1 days;
        uint256 accruedInterest = Math.mulDiv(
            loan.principalAmount, loan.accruingInterestDailyRate * accruingDays, DAILY_INTEREST_DENOMINATOR
        );
        return loan.fixedInterestAmount + accruedInterest;
    }


    /*----------------------------------------------------------*|
    |*  # CLAIM LOAN                                            *|
    |*----------------------------------------------------------*/

    /**
     * @notice Claim a repaid or defaulted loan.
     * @dev Only a LOAN token holder can claim a repaid or defaulted loan.
     *      Claim will transfer the repaid credit or collateral to a LOAN token holder address and burn the LOAN token.
     * @param loanId Id of a loan that is being claimed.
     */
    function claimLOAN(uint256 loanId) external {
        LOAN storage loan = LOANs[loanId];

        // Check that caller is LOAN token holder
        if (loanToken.ownerOf(loanId) != msg.sender)
            revert CallerNotLOANTokenHolder();

        // Loan is not existing or from a different loan contract
        if (loan.status == 0)
            revert NonExistingLoan();
        // Loan has been paid back
        else if (loan.status == 3)
            _settleLoanClaim({ loanId: loanId, loanOwner: msg.sender, defaulted: false });
        // Loan is running but expired
        else if (loan.status == 2 && loan.defaultTimestamp <= block.timestamp)
            _settleLoanClaim({ loanId: loanId, loanOwner: msg.sender, defaulted: true });
        // Loan is in wrong state
        else
            revert InvalidLoanStatus(loan.status);
    }

    /**
     * @notice Try to claim a repaid loan for the loan owner.
     * @dev The function is called by the vault to repay a loan directly to the original lender or its source of funds
     *      if the loan owner is the original lender. If the transfer fails, the LOAN token will remain in repaid state
     *      and the LOAN token owner will be able to claim the repaid credit. Otherwise lender would be able to prevent
     *      borrower from repaying the loan.
     * @param loanId Id of a loan that is being claimed.
     * @param loanOwner Address of the LOAN token holder.
     */
    function tryClaimRepaidLOANForLoanOwner(uint256 loanId, address loanOwner) external {
        if (msg.sender != address(this))
            revert CallerNotVault();

        LOAN storage loan = LOANs[loanId];

        if (loan.status != 3)
            return;

        // If current loan owner is not original lender, the loan cannot be repaid directly, return without revert.
        if (loan.originalLender != loanOwner)
            return;

        // Note: The loan owner is the original lender at this point.

        address destinationOfFunds = loan.originalSourceOfFunds;
        MultiToken.Asset memory repaymentCredit = loan.creditAddress.ERC20(_loanRepaymentAmount(loanId));

        // Delete loan data & burn LOAN token before calling safe transfer
        _deleteLoan(loanId);

        // Repay the original lender
        if (destinationOfFunds == loanOwner) {
            _push(repaymentCredit, loanOwner);
        } else {
            // Supply the repaid credit to the Compound pool
            MultiToken.approveAsset(repaymentCredit, destinationOfFunds);
            _supplyToCompound(repaymentCredit, destinationOfFunds, loanOwner);
        }

        // Note: If the transfer fails, the LOAN token will remain in repaid state and the LOAN token owner
        // will be able to claim the repaid credit. Otherwise lender would be able to prevent borrower from
        // repaying the loan.

        emit LOANClaimed({ loanId: loanId, defaulted: false });
    }

    /**
     * @notice Settle the loan claim.
     * @param loanId Id of a loan that is being claimed.
     * @param loanOwner Address of the LOAN token holder.
     * @param defaulted If the loan is defaulted.
     */
    function _settleLoanClaim(uint256 loanId, address loanOwner, bool defaulted) private {
        LOAN storage loan = LOANs[loanId];

        // Store in memory before deleting the loan
        MultiToken.Asset memory asset = defaulted
            ? loan.collateral
            : loan.creditAddress.ERC20(_loanRepaymentAmount(loanId));

        // Delete loan data & burn LOAN token before calling safe transfer
        _deleteLoan(loanId);

        emit LOANClaimed({ loanId: loanId, defaulted: defaulted });

        // Transfer asset to current LOAN token owner
        _push(asset, loanOwner);
    }

    /**
     * @notice Delete loan data and burn LOAN token.
     * @param loanId Id of a loan that is being deleted.
     */
    function _deleteLoan(uint256 loanId) private {
        loanToken.burn(loanId);
        delete LOANs[loanId];
    }


    /*----------------------------------------------------------*|
    |*  # EXTEND LOAN                                           *|
    |*----------------------------------------------------------*/

    /**
     * @notice Make an on-chain extension proposal.
     * @param extension Extension proposal struct.
     */
    function makeExtensionProposal(ExtensionProposal calldata extension) external {
        // Check that caller is a proposer
        if (msg.sender != extension.proposer)
            revert InvalidExtensionSigner({ allowed: extension.proposer, current: msg.sender });

        // Mark extension proposal as made
        bytes32 extensionHash = getExtensionHash(extension);
        extensionProposalsMade[extensionHash] = true;

        emit ExtensionProposalMade(extensionHash, extension.proposer, extension);
    }

    /**
     * @notice Extend loans default date with signed extension proposal signed by borrower or LOAN token owner.
     * @dev The function assumes a prior token approval to a contract address or a signed permit.
     * @param extension Extension proposal struct.
     * @param signature Signature of the extension proposal.
     * @param permit Callers permit.
     */
    function extendLOAN(
        ExtensionProposal calldata extension,
        bytes calldata signature,
        Permit calldata permit
    ) external {
        LOAN storage loan = LOANs[extension.loanId];

        // Check that loan is in the right state
        if (loan.status == 0)
            revert NonExistingLoan();
        if (loan.status == 3) // cannot extend repaid loan
            revert InvalidLoanStatus(loan.status);

        // Check extension validity
        bytes32 extensionHash = getExtensionHash(extension);
        if (!extensionProposalsMade[extensionHash])
            if (!PWNSignatureChecker.isValidSignatureNow(extension.proposer, extensionHash, signature))
                revert InvalidSignature({ signer: extension.proposer, digest: extensionHash });

        // Check extension expiration
        if (block.timestamp >= extension.expiration)
            revert Expired({ current: block.timestamp, expiration: extension.expiration });

        // Check extension nonce
        if (!revokedNonce.isNonceUsable(extension.proposer, extension.nonceSpace, extension.nonce))
            revert NonceNotUsable({ addr: extension.proposer, nonceSpace: extension.nonceSpace, nonce: extension.nonce });

        // Check caller and signer
        address loanOwner = loanToken.ownerOf(extension.loanId);
        if (msg.sender == loanOwner) {
            if (extension.proposer != loan.borrower) {
                // If caller is loan owner, proposer must be borrower
                revert InvalidExtensionSigner({
                    allowed: loan.borrower,
                    current: extension.proposer
                });
            }
        } else if (msg.sender == loan.borrower) {
            if (extension.proposer != loanOwner) {
                // If caller is borrower, proposer must be loan owner
                revert InvalidExtensionSigner({
                    allowed: loanOwner,
                    current: extension.proposer
                });
            }
        } else {
            // Caller must be loan owner or borrower
            revert InvalidExtensionCaller();
        }

        // Check duration range
        if (extension.duration < MIN_EXTENSION_DURATION)
            revert InvalidExtensionDuration({
                duration: extension.duration,
                limit: MIN_EXTENSION_DURATION
            });
        if (extension.duration > MAX_EXTENSION_DURATION)
            revert InvalidExtensionDuration({
                duration: extension.duration,
                limit: MAX_EXTENSION_DURATION
            });

        // Revoke extension proposal nonce
        revokedNonce.revokeNonce(extension.proposer, extension.nonceSpace, extension.nonce);

        // Update loan
        uint40 originalDefaultTimestamp = loan.defaultTimestamp;
        loan.defaultTimestamp = originalDefaultTimestamp + extension.duration;

        // Emit event
        emit LOANExtended({
            loanId: extension.loanId,
            originalDefaultTimestamp: originalDefaultTimestamp,
            extendedDefaultTimestamp: loan.defaultTimestamp
        });

        // Skip compensation transfer if it's not set
        if (extension.compensationAddress != address(0) && extension.compensationAmount > 0) {
            MultiToken.Asset memory compensation = extension.compensationAddress.ERC20(extension.compensationAmount);

            // Check compensation asset validity
            _checkValidAsset(compensation);

            // Transfer compensation to the loan owner
            _checkPermit(msg.sender, extension.compensationAddress, permit);
            _tryPermit(permit);
            _pushFrom(compensation, loan.borrower, loanOwner);
        }
    }

    /**
     * @notice Get the hash of the extension struct.
     * @param extension Extension proposal struct.
     * @return Hash of the extension struct.
     */
    function getExtensionHash(ExtensionProposal calldata extension) public view returns (bytes32) {
        return keccak256(abi.encodePacked(
            hex"1901",
            DOMAIN_SEPARATOR,
            keccak256(abi.encodePacked(
                EXTENSION_PROPOSAL_TYPEHASH,
                abi.encode(extension)
            ))
        ));
    }


    /*----------------------------------------------------------*|
    |*  # GET LOAN                                              *|
    |*----------------------------------------------------------*/

    /**
     * @notice Return a LOAN data struct associated with a loan id.
     * @param loanId Id of a loan in question.
     * @return status LOAN status.
     * @return startTimestamp Unix timestamp (in seconds) of a loan creation date.
     * @return defaultTimestamp Unix timestamp (in seconds) of a loan default date.
     * @return borrower Address of a loan borrower.
     * @return originalLender Address of a loan original lender.
     * @return loanOwner Address of a LOAN token holder.
     * @return accruingInterestDailyRate Daily interest rate in basis points.
     * @return fixedInterestAmount Fixed interest amount in credit asset tokens.
     * @return credit Asset used as a loan credit. For a definition see { MultiToken dependency lib }.
     * @return collateral Asset used as a loan collateral. For a definition see { MultiToken dependency lib }.
     * @return originalSourceOfFunds Address of a source of funds for the loan. Original lender address, if the loan was funded directly, or a pool address from witch credit funds were withdrawn / borrowred.
     * @return repaymentAmount Loan repayment amount in credit asset tokens.
     */
    function getLOAN(uint256 loanId) external view returns (
        uint8 status,
        uint40 startTimestamp,
        uint40 defaultTimestamp,
        address borrower,
        address originalLender,
        address loanOwner,
        uint40 accruingInterestDailyRate,
        uint256 fixedInterestAmount,
        MultiToken.Asset memory credit,
        MultiToken.Asset memory collateral,
        address originalSourceOfFunds,
        uint256 repaymentAmount
    ) {
        LOAN storage loan = LOANs[loanId];

        status = _getLOANStatus(loanId);
        startTimestamp = loan.startTimestamp;
        defaultTimestamp = loan.defaultTimestamp;
        borrower = loan.borrower;
        originalLender = loan.originalLender;
        loanOwner = loan.status != 0 ? loanToken.ownerOf(loanId) : address(0);
        accruingInterestDailyRate = loan.accruingInterestDailyRate;
        fixedInterestAmount = loan.fixedInterestAmount;
        credit = loan.creditAddress.ERC20(loan.principalAmount);
        collateral = loan.collateral;
        originalSourceOfFunds = loan.originalSourceOfFunds;
        repaymentAmount = loanRepaymentAmount(loanId);
    }

    /**
     * @notice Return a LOAN status associated with a loan id.
     * @param loanId Id of a loan in question.
     * @return status LOAN status.
     */
    function _getLOANStatus(uint256 loanId) private view returns (uint8) {
        LOAN storage loan = LOANs[loanId];
        return (loan.status == 2 && loan.defaultTimestamp <= block.timestamp) ? 4 : loan.status;
    }


    /*----------------------------------------------------------*|
    |*  # MultiToken                                            *|
    |*----------------------------------------------------------*/

    /**
     * @notice Check if the asset is valid with the MultiToken dependency lib and the category registry.
     * @dev See MultiToken.isValid for more details.
     * @param asset Asset to be checked.
     * @return True if the asset is valid.
     */
    function isValidAsset(MultiToken.Asset memory asset) public view returns (bool) {
        return MultiToken.isValid(asset, categoryRegistry);
    }

    /**
     * @notice Check if the asset is valid with the MultiToken lib and the category registry.
     * @dev The function will revert if the asset is not valid.
     * @param asset Asset to be checked.
     */
    function _checkValidAsset(MultiToken.Asset memory asset) private view {
        if (!isValidAsset(asset)) {
            revert InvalidMultiTokenAsset({
                category: uint8(asset.category),
                addr: asset.assetAddress,
                id: asset.id,
                amount: asset.amount
            });
        }
    }


    /*----------------------------------------------------------*|
    |*  # IPWNLoanMetadataProvider                              *|
    |*----------------------------------------------------------*/

    /**
     * @inheritdoc IPWNLoanMetadataProvider
     */
    function loanMetadataUri() override external view returns (string memory) {
        return config.loanMetadataUri(address(this));
    }


    /*----------------------------------------------------------*|
    |*  # ERC5646                                               *|
    |*----------------------------------------------------------*/

    /**
     * @inheritdoc IERC5646
     */
    function getStateFingerprint(uint256 tokenId) external view virtual override returns (bytes32) {
        LOAN storage loan = LOANs[tokenId];

        if (loan.status == 0)
            return bytes32(0);

        // The only mutable state properties are:
        // - status: updated for expired loans based on block.timestamp
        // - defaultTimestamp: updated when the loan is extended
        // - fixedInterestAmount: updated when the loan is repaid and waiting to be claimed
        // - accruingInterestDailyRate: updated when the loan is repaid and waiting to be claimed
        // Others don't have to be part of the state fingerprint as it does not act as a token identification.
        return keccak256(abi.encode(
            _getLOANStatus(tokenId),
            loan.defaultTimestamp,
            loan.fixedInterestAmount,
            loan.accruingInterestDailyRate
        ));
    }

}
