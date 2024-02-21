// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.16;

import { MultiToken, IMultiTokenCategoryRegistry } from "MultiToken/MultiToken.sol";

import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import { PWNConfig } from "@pwn/config/PWNConfig.sol";
import { PWNHub } from "@pwn/hub/PWNHub.sol";
import { PWNHubTags } from "@pwn/hub/PWNHubTags.sol";
import { PWNFeeCalculator } from "@pwn/loan/lib/PWNFeeCalculator.sol";
import { PWNLOANTerms } from "@pwn/loan/terms/PWNLOANTerms.sol";
import { PWNSimpleLoanTermsFactory } from "@pwn/loan/terms/simple/factory/PWNSimpleLoanTermsFactory.sol";
import { IERC5646 } from "@pwn/loan/token/IERC5646.sol";
import { IPWNLoanMetadataProvider } from "@pwn/loan/token/IPWNLoanMetadataProvider.sol";
import { PWNLOAN } from "@pwn/loan/token/PWNLOAN.sol";
import { PWNVault } from "@pwn/loan/PWNVault.sol";
import "@pwn/PWNErrors.sol";


/**
 * @title PWN Simple Loan
 * @notice Contract managing a simple loan in PWN protocol.
 * @dev Acts as a vault for every loan created by this contract.
 */
contract PWNSimpleLoan is PWNVault, IERC5646, IPWNLoanMetadataProvider {

    string public constant VERSION = "1.2";
    uint256 public constant MAX_EXPIRATION_EXTENSION = 2_592_000; // 30 days

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    PWNHub internal immutable hub;
    PWNLOAN internal immutable loanToken;
    PWNConfig internal immutable config;

    IMultiTokenCategoryRegistry public immutable categoryRegistry;

    /**
     * @notice Struct defining a simple loan.
     * @param status 0 == none/dead || 2 == running/accepted offer/accepted request || 3 == paid back || 4 == expired.
     * @param borrower Address of a borrower.
     * @param expiration Unix timestamp (in seconds) setting up a default date.
     * @param loanAssetAddress Address of an asset used as a loan credit.
     * @param loanRepayAmount Amount of a loan asset to be paid back.
     * @param collateral Asset used as a loan collateral. For a definition see { MultiToken dependency lib }.
     * @param originalLender Address of a lender that funded the loan.
     */
    struct LOAN {
        uint8 status;
        address borrower;
        uint40 expiration;
        address loanAssetAddress;
        uint256 loanRepayAmount;
        MultiToken.Asset collateral;
        address originalLender;
    }

    /**
     * Mapping of all LOAN data by loan id.
     */
    mapping (uint256 => LOAN) private LOANs;


    /*----------------------------------------------------------*|
    |*  # EVENTS & ERRORS DEFINITIONS                           *|
    |*----------------------------------------------------------*/

    /**
     * @dev Emitted when a new loan in created.
     */
    event LOANCreated(uint256 indexed loanId, PWNLOANTerms.Simple terms, bytes32 indexed factoryDataHash, address indexed factoryAddress);

    /**
     * @dev Emitted when a loan is paid back.
     */
    event LOANPaidBack(uint256 indexed loanId);

    /**
     * @dev Emitted when a repaid or defaulted loan is claimed.
     */
    event LOANClaimed(uint256 indexed loanId, bool indexed defaulted);

    /**
     * @dev Emitted when a LOAN token holder extends loan expiration date.
     */
    event LOANExpirationDateExtended(uint256 indexed loanId, uint40 extendedExpirationDate);


    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR                                           *|
    |*----------------------------------------------------------*/

    constructor(address _hub, address _loanToken, address _config, address _categoryRegistry) {
        hub = PWNHub(_hub);
        loanToken = PWNLOAN(_loanToken);
        config = PWNConfig(_config);
        categoryRegistry = IMultiTokenCategoryRegistry(_categoryRegistry);
    }


    /*----------------------------------------------------------*|
    |*  # CREATE LOAN                                           *|
    |*----------------------------------------------------------*/

    /**
     * @notice Create a new loan by minting LOAN token for lender, transferring loan asset to a borrower and a collateral to a vault.
     * @dev The function assumes a prior token approval to a contract address or signed permits.
     * @param loanTermsFactoryContract Address of a loan terms factory contract. Need to have `SIMPLE_LOAN_TERMS_FACTORY` tag in PWN Hub.
     * @param loanTermsFactoryData Encoded data for a loan terms factory.
     * @param signature Signed loan factory data. Could be empty if an offer / request has been made via on-chain transaction.
     * @param loanAssetPermit Permit data for a loan asset signed by a lender.
     * @param collateralPermit Permit data for a collateral signed by a borrower.
     * @return loanId Id of a newly minted LOAN token.
     */
    function createLOAN(
        address loanTermsFactoryContract,
        bytes calldata loanTermsFactoryData,
        bytes calldata signature,
        bytes calldata loanAssetPermit,
        bytes calldata collateralPermit
    ) external returns (uint256 loanId) {
        // Create loan terms or revert if factory contract is not tagged in PWN Hub
        (PWNLOANTerms.Simple memory loanTerms, bytes32 factoryDataHash)
            = _createLoanTerms(loanTermsFactoryContract, loanTermsFactoryData, signature);

        // Check loan asset validity
        if (!MultiToken.isValid(loanTerms.asset, categoryRegistry))
            revert InvalidLoanAsset();

        // Check collateral validity
        if (!MultiToken.isValid(loanTerms.collateral, categoryRegistry))
            revert InvalidCollateralAsset();

        // Create a new loan
        loanId = _createLoan(loanTerms, factoryDataHash, loanTermsFactoryContract);

        // Transfer collateral to Vault and loan asset to borrower
        _settleNewLoan(loanTerms, loanAssetPermit, collateralPermit);
    }

    /**
     * @notice Create a loan terms by a loan terms factory contract.
     * @dev The function will revert if the loan terms factory contract is not tagged in PWN Hub.
     * @param loanTermsFactoryContract Address of a loan terms factory contract. Need to have `SIMPLE_LOAN_TERMS_FACTORY` tag in PWN Hub.
     * @param loanTermsFactoryData Encoded data for a loan terms factory.
     * @param signature Signed loan factory data. Could be empty if an offer / request has been made via on-chain transaction.
     * @return loanTerms Loan terms struct.
     * @return factoryDataHash Hash of the factory data.
     */
    function _createLoanTerms(
        address loanTermsFactoryContract,
        bytes calldata loanTermsFactoryData,
        bytes calldata signature
    ) private returns (PWNLOANTerms.Simple memory loanTerms, bytes32 factoryDataHash) {
        // Check that loan terms factory contract is tagged in PWNHub
        if (!hub.hasTag(loanTermsFactoryContract, PWNHubTags.SIMPLE_LOAN_TERMS_FACTORY))
            revert CallerMissingHubTag(PWNHubTags.SIMPLE_LOAN_TERMS_FACTORY);

        // Build PWNLOANTerms.Simple by loan factory
        (loanTerms, factoryDataHash) = PWNSimpleLoanTermsFactory(loanTermsFactoryContract).createLOANTerms({
            caller: msg.sender,
            factoryData: loanTermsFactoryData,
            signature: signature
        });
    }

    /**
     * @notice Store a new loan in the contract state, mints new LOAN token, and emit a `LOANCreated` event.
     * @param loanTerms Loan terms struct.
     * @param factoryDataHash Hash of the factory data.
     * @param loanTermsFactoryContract Address of a loan terms factory contract.
     * @return loanId Id of a newly minted LOAN token.
     */
    function _createLoan(
        PWNLOANTerms.Simple memory loanTerms,
        bytes32 factoryDataHash,
        address loanTermsFactoryContract
    ) private returns (uint256 loanId) {
        // Mint LOAN token for lender
        loanId = loanToken.mint(loanTerms.lender);

        // Store loan data under loan id
        LOAN storage loan = LOANs[loanId];
        loan.status = 2;
        loan.borrower = loanTerms.borrower;
        loan.expiration = loanTerms.expiration;
        loan.loanAssetAddress = loanTerms.asset.assetAddress;
        loan.loanRepayAmount = loanTerms.loanRepayAmount;
        loan.collateral = loanTerms.collateral;
        loan.originalLender = loanTerms.lender;

        emit LOANCreated({
            loanId: loanId,
            terms: loanTerms,
            factoryDataHash: factoryDataHash,
            factoryAddress: loanTermsFactoryContract
        });
    }

    /**
     * @notice Transfer collateral to Vault and loan asset to borrower.
     * @dev The function assumes a prior token approval to a contract address or signed permits.
     * @param loanTerms Loan terms struct.
     * @param loanAssetPermit Permit data for a loan asset signed by a lender.
     * @param collateralPermit Permit data for a collateral signed by a borrower.
     */
    function _settleNewLoan(
        PWNLOANTerms.Simple memory loanTerms,
        bytes calldata loanAssetPermit,
        bytes calldata collateralPermit
    ) private {
        // Transfer collateral to Vault
        _permit(loanTerms.collateral, loanTerms.borrower, collateralPermit);
        _pull(loanTerms.collateral, loanTerms.borrower);

        // Permit loan asset spending if permit provided
        _permit(loanTerms.asset, loanTerms.lender, loanAssetPermit);

        // Collect fee if any and update loan asset amount
        (uint256 feeAmount, uint256 newLoanAmount)
            = PWNFeeCalculator.calculateFeeAmount(config.fee(), loanTerms.asset.amount);
        if (feeAmount > 0) {
            // Transfer fee amount to fee collector
            loanTerms.asset.amount = feeAmount;
            _pushFrom(loanTerms.asset, loanTerms.lender, config.feeCollector());

            // Set new loan amount value
            loanTerms.asset.amount = newLoanAmount;
        }

        // Transfer loan asset to borrower
        _pushFrom(loanTerms.asset, loanTerms.lender, loanTerms.borrower);
    }


    /*----------------------------------------------------------*|
    |*  # REFINANCE LOAN                                        *|
    |*----------------------------------------------------------*/

    /**
     * @notice Refinance a loan by repaying the original loan and creating a new one.
     * @dev If the new lender is the same as the current LOAN owner,
     *      the function will transfer only the surplus to the borrower, if any.
     *      If the new loan amount is not enough to cover the original loan, the borrower needs to contribute.
     *      The function assumes a prior token approval to a contract address or signed permits.
     * @param loanId Id of a loan that is being refinanced.
     * @param loanTermsFactoryContract Address of a loan terms factory contract. Need to have `SIMPLE_LOAN_TERMS_FACTORY` tag in PWN Hub.
     * @param loanTermsFactoryData Encoded data for a loan terms factory.
     * @param signature Signed loan factory data. Could be empty if an offer / request has been made via on-chain transaction.
     * @param lenderLoanAssetPermit Permit data for a loan asset signed by a lender.
     * @param borrowerLoanAssetPermit Permit data for a loan asset signed by a borrower.
     * @return refinancedLoanId Id of the refinanced LOAN token.
     */
    function refinanceLOAN(
        uint256 loanId,
        address loanTermsFactoryContract,
        bytes calldata loanTermsFactoryData,
        bytes calldata signature,
        bytes calldata lenderLoanAssetPermit,
        bytes calldata borrowerLoanAssetPermit
    ) external returns (uint256 refinancedLoanId) {
        LOAN storage loan = LOANs[loanId];

        // Check that the original loan can be repaid, revert if not
        _checkLoanCanBeRepaid(loan.status, loan.expiration);

        // Create loan terms or revert if factory contract is not tagged in PWN Hub
        (PWNLOANTerms.Simple memory loanTerms, bytes32 factoryDataHash)
            = _createLoanTerms(loanTermsFactoryContract, loanTermsFactoryData, signature);

        // Check loan terms validity, revert if not
        _checkRefinanceLoanTerms(loan, loanTerms);

        // Create a new loan
        refinancedLoanId = _createLoan(loanTerms, factoryDataHash, loanTermsFactoryContract);

        // Refinance the original loan
        _refinanceOriginalLoan(
            loanId,
            loan.loanRepayAmount,
            loanTerms,
            lenderLoanAssetPermit,
            borrowerLoanAssetPermit
        );
    }

    /**
     * @notice Check if the loan terms are valid for refinancing.
     * @dev The function will revert if the loan terms are not valid for refinancing.
     * @param loan Original loan struct.
     * @param loanTerms Refinancing loan terms struct.
     */
    function _checkRefinanceLoanTerms(LOAN storage loan, PWNLOANTerms.Simple memory loanTerms) private view {
        // Check that the loan asset is the same as in the original loan
        // Note: Address check is enough because the asset has always ERC20 category and zero id.
        // Amount can be different, but nonzero.
        if (
            loan.loanAssetAddress != loanTerms.asset.assetAddress ||
            loanTerms.asset.amount == 0
        ) revert InvalidLoanAsset();

        // Check that the collateral is identical to the original one
        if (
            loan.collateral.category != loanTerms.collateral.category ||
            loan.collateral.assetAddress != loanTerms.collateral.assetAddress ||
            loan.collateral.id != loanTerms.collateral.id ||
            loan.collateral.amount != loanTerms.collateral.amount
        ) revert InvalidCollateralAsset();

        // Check that the borrower is the same as in the original loan
        if (loan.borrower != loanTerms.borrower) {
            revert BorrowerMismatch({
                currentBorrower: loan.borrower,
                newBorrower: loanTerms.borrower
            });
        }
    }

    /**
     * @notice Repay the original loan and transfer the surplus to the borrower if any.
     * @dev If the new lender is the same as the current LOAN owner,
     *      the function will transfer only the surplus to the borrower, if any.
     *      If the new loan amount is not enough to cover the original loan, the borrower needs to contribute.
     *      The function assumes a prior token approval to a contract address or signed permits.
     * @param loanId Id of a loan that is being refinanced.
     * @param loanRepayAmount Amount of the original loan to be repaid.
     * @param loanTerms Loan terms struct.
     * @param lenderLoanAssetPermit Permit data for a loan asset signed by a lender.
     * @param borrowerLoanAssetPermit Permit data for a loan asset signed by a borrower.
     */
    function _refinanceOriginalLoan(
        uint256 loanId,
        uint256 loanRepayAmount,
        PWNLOANTerms.Simple memory loanTerms,
        bytes calldata lenderLoanAssetPermit,
        bytes calldata borrowerLoanAssetPermit
    ) private {
        // Delete or update the original loan
        (bool repayLoanDirectly, address loanOwner) = _deleteOrUpdateRepaidLoan(loanId);

        // Repay the original loan and transfer the surplus to the borrower if any
        _settleLoanRefinance({
            repayLoanDirectly: repayLoanDirectly,
            loanOwner: loanOwner,
            loanRepayAmount: loanRepayAmount,
            loanTerms: loanTerms,
            lenderPermit: lenderLoanAssetPermit,
            borrowerPermit: borrowerLoanAssetPermit
        });
    }

    /**
     * @notice Settle the refinanced loan. If the new lender is the same as the current LOAN owner,
     *         the function will transfer only the surplus to the borrower, if any.
     *         If the new loan amount is not enough to cover the original loan, the borrower needs to contribute.
     *         The function assumes a prior token approval to a contract address or signed permits.
     * @param repayLoanDirectly If the loan can be repaid directly to the current LOAN owner.
     * @param loanOwner Address of the current LOAN owner.
     * @param loanRepayAmount Amount of the original loan to be repaid.
     * @param loanTerms Loan terms struct.
     * @param lenderPermit Permit data for a loan asset signed by a lender.
     * @param borrowerPermit Permit data for a loan asset signed by a borrower.
     */
    function _settleLoanRefinance(
        bool repayLoanDirectly,
        address loanOwner,
        uint256 loanRepayAmount,
        PWNLOANTerms.Simple memory loanTerms,
        bytes calldata lenderPermit,
        bytes calldata borrowerPermit
    ) private {
        MultiToken.Asset memory loanAssetHelper = MultiToken.ERC20(loanTerms.asset.assetAddress, 0);

        // Compute fee size
        (uint256 feeAmount, uint256 newLoanAmount)
            = PWNFeeCalculator.calculateFeeAmount(config.fee(), loanTerms.asset.amount);

        // Set new loan amount value
        loanTerms.asset.amount = newLoanAmount;

        // Note: At this point `loanTerms` struct has loan asset amount deducted by the fee amount.

        // Permit lenders loan asset spending if permit provided
        loanAssetHelper.amount = loanTerms.asset.amount + feeAmount; // Permit the whole loan amount + fee
        loanAssetHelper.amount -= loanTerms.lender == loanOwner // Permit only the surplus transfer + fee
            ? Math.min(loanRepayAmount, loanTerms.asset.amount) : 0;
        if (loanAssetHelper.amount > 0)
            _permit(loanAssetHelper, loanTerms.lender, lenderPermit);

        // Collect fees
        if (feeAmount > 0) {
            loanAssetHelper.amount = feeAmount;
            _pushFrom(loanAssetHelper, loanTerms.lender, config.feeCollector());
        }

        // If the new lender is the LOAN token owner, don't execute the transfer at all,
        // it would make transfer from the same address to the same address
        if (loanTerms.lender != loanOwner) {
            loanAssetHelper.amount = Math.min(loanRepayAmount, loanTerms.asset.amount);
            _transferLoanRepayment({
                repayLoanDirectly: repayLoanDirectly,
                asset: loanAssetHelper,
                repayingAddress: loanTerms.lender,
                currentLoanOwner: loanOwner
            });
        }

        if (loanTerms.asset.amount >= loanRepayAmount) {
            // New loan covers the whole original loan, transfer surplus to the borrower if any
            uint256 surplus = loanTerms.asset.amount - loanRepayAmount;
            if (surplus > 0) {
                loanAssetHelper.amount = surplus;
                _pushFrom(loanAssetHelper, loanTerms.lender, loanTerms.borrower);
            }
        } else {
            // Permit borrowers loan asset spending if permit provided
            loanAssetHelper.amount = loanRepayAmount - loanTerms.asset.amount;
            _permit(loanAssetHelper, loanTerms.borrower, borrowerPermit);

            // New loan covers only part of the original loan, borrower needs to contribute
            _transferLoanRepayment({
                repayLoanDirectly: repayLoanDirectly || loanTerms.lender == loanOwner,
                asset: loanAssetHelper,
                repayingAddress: loanTerms.borrower,
                currentLoanOwner: loanOwner
            });
        }
    }


    /*----------------------------------------------------------*|
    |*  # REPAY LOAN                                            *|
    |*----------------------------------------------------------*/

    /**
     * @notice Repay running loan.
     * @dev Any address can repay a running loan, but a collateral will be transferred to a borrower address associated with the loan.
     *      Repay will transfer a loan asset to a vault, waiting on a LOAN token holder to claim it.
     *      The function assumes a prior token approval to a contract address or a signed  permit.
     * @param loanId Id of a loan that is being repaid.
     * @param loanAssetPermit Permit data for a loan asset signed by a borrower.
     */
    function repayLOAN(
        uint256 loanId,
        bytes calldata loanAssetPermit
    ) external {
        LOAN memory loan = LOANs[loanId];

        _checkLoanCanBeRepaid(loan.status, loan.expiration);

        (bool repayLoanDirectly, address loanOwner) = _deleteOrUpdateRepaidLoan(loanId);

        _settleLoanRepayment({
            repayLoanDirectly: repayLoanDirectly,
            loanOwner: loanOwner,
            repayingAddress: msg.sender,
            borrower: loan.borrower,
            repayLoanAsset: MultiToken.ERC20(loan.loanAssetAddress, loan.loanRepayAmount),
            collateral: loan.collateral,
            loanAssetPermit: loanAssetPermit
        });
    }

    /**
     * @notice Check if the loan can be repaid.
     * @dev The function will revert if the loan cannot be repaid.
     * @param status Loan status.
     * @param expiration Loan expiration date.
     */
    function _checkLoanCanBeRepaid(uint8 status, uint40 expiration) private view {
        // Check that loan exists and is not from a different loan contract
        if (status == 0) revert NonExistingLoan();
        // Check that loan is running
        if (status != 2) revert InvalidLoanStatus(status);
        // Check that loan is not expired
        if (expiration <= block.timestamp) revert LoanDefaulted(expiration);
    }

    /**
     * @notice Delete or update the original loan.
     * @dev If the loan can be repaid directly to the current LOAN owner,
     *      the function will delete the loan and burn the LOAN token.
     *      If the loan cannot be repaid directly to the current LOAN owner,
     *      the function will move the loan to repaid state and wait for the lender to claim the repaid loan asset.
     * @param loanId Id of a loan that is being repaid.
     * @return repayLoanDirectly If the loan can be repaid directly to the current LOAN owner.
     * @return loanOwner Address of the current LOAN owner.
     */
    function _deleteOrUpdateRepaidLoan(uint256 loanId) private returns (bool repayLoanDirectly, address loanOwner) {
        emit LOANPaidBack({ loanId: loanId });

        // Note: Assuming that it is safe to transfer the loan asset to the original lender
        // if the lender still owns the LOAN token because the lender was able to sign an offer
        // or make a contract call, thus can handle incoming transfers.
        loanOwner = loanToken.ownerOf(loanId);
        repayLoanDirectly = LOANs[loanId].originalLender == loanOwner;
        if (repayLoanDirectly) {
            // Delete loan data & burn LOAN token before calling safe transfer
            _deleteLoan(loanId);

            emit LOANClaimed({ loanId: loanId, defaulted: false });
        } else {
            // Move loan to repaid state and wait for the lender to claim the repaid loan asset
            LOANs[loanId].status = 3;
        }
    }

    /**
     * @notice Settle the loan repayment.
     * @dev The function assumes a prior token approval to a contract address or a signed permit.
     * @param repayLoanDirectly If the loan can be repaid directly to the current LOAN owner.
     * @param loanOwner Address of the current LOAN owner.
     * @param repayingAddress Address of the account repaying the loan.
     * @param borrower Address of the borrower associated with the loan.
     * @param repayLoanAsset Loan asset to be repaid.
     * @param collateral Collateral to be transferred back to the borrower.
     * @param loanAssetPermit Permit data for a loan asset signed by a borrower.
     */
    function _settleLoanRepayment(
        bool repayLoanDirectly,
        address loanOwner,
        address repayingAddress,
        address borrower,
        MultiToken.Asset memory repayLoanAsset,
        MultiToken.Asset memory collateral,
        bytes calldata loanAssetPermit
    ) private {
        // Transfer loan asset to the original lender or to the Vault
        _permit(repayLoanAsset, repayingAddress, loanAssetPermit);
        _transferLoanRepayment(repayLoanDirectly, repayLoanAsset, repayingAddress, loanOwner);

        // Transfer collateral back to borrower
        _push(collateral, borrower);
    }

    /**
     * @notice Transfer the repaid loan asset to the original lender or to the Vault.
     * @param repayLoanDirectly If the loan can be repaid directly to the current LOAN owner.
     * @param asset Asset to be repaid.
     * @param repayingAddress Address of the account repaying the loan.
     * @param currentLoanOwner Address of the current LOAN owner.
     */
    function _transferLoanRepayment(
        bool repayLoanDirectly,
        MultiToken.Asset memory asset,
        address repayingAddress,
        address currentLoanOwner
    ) private {
        if (repayLoanDirectly) {
            // Transfer the repaid loan asset to the LOAN token owner
            _pushFrom(asset, repayingAddress, currentLoanOwner);
        } else {
            // Transfer the repaid loan asset to the Vault
            _pull(asset, repayingAddress);
        }
    }


    /*----------------------------------------------------------*|
    |*  # CLAIM LOAN                                            *|
    |*----------------------------------------------------------*/

    /**
     * @notice Claim a repaid or defaulted loan.
     * @dev Only a LOAN token holder can claim a repaid or defaulted loan.
     *      Claim will transfer the repaid loan asset or collateral to a LOAN token holder address and burn the LOAN token.
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
        else if (loan.status == 2 && loan.expiration <= block.timestamp)
            _settleLoanClaim({ loanId: loanId, loanOwner: msg.sender, defaulted: true });
        // Loan is in wrong state
        else
            revert InvalidLoanStatus(loan.status);
    }

    /**
     * @notice Settle the loan claim.
     * @param loanId Id of a loan that is being claimed.
     * @param loanOwner Address of the LOAN token holder.
     * @param defaulted If the loan is defaulted.
     */
    function _settleLoanClaim(uint256 loanId, address loanOwner, bool defaulted) private {
        LOAN storage loan = LOANs[loanId];

        MultiToken.Asset memory asset = defaulted
            ? loan.collateral
            : MultiToken.ERC20(loan.loanAssetAddress, loan.loanRepayAmount);

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
    |*  # EXTEND LOAN EXPIRATION DATE                           *|
    |*----------------------------------------------------------*/

    /**
     * @notice Enable lender to extend loans expiration date.
     * @dev Only LOAN token holder can call this function.
     *      Extending the expiration date of a repaid loan is allowed, but considered a lender mistake.
     *      The extended expiration date has to be in the future, be later than the current expiration date, and cannot be extending the date by more than `MAX_EXPIRATION_EXTENSION`.
     * @param loanId Id of a LOAN to extend its expiration date.
     * @param extendedExpirationDate New LOAN expiration date.
     */
    function extendLOANExpirationDate(uint256 loanId, uint40 extendedExpirationDate) external {
        // Check that caller is LOAN token holder
        // This prevents from extending non-existing loans
        if (loanToken.ownerOf(loanId) != msg.sender)
            revert CallerNotLOANTokenHolder();

        LOAN storage loan = LOANs[loanId];

        // Check extended expiration date
        if (extendedExpirationDate > uint40(block.timestamp + MAX_EXPIRATION_EXTENSION)) // to protect lender
            revert InvalidExtendedExpirationDate();
        if (extendedExpirationDate <= uint40(block.timestamp)) // have to extend expiration futher in time
            revert InvalidExtendedExpirationDate();
        if (extendedExpirationDate <= loan.expiration) // have to be later than current expiration date
            revert InvalidExtendedExpirationDate();

        // Extend expiration date
        loan.expiration = extendedExpirationDate;

        emit LOANExpirationDateExtended({ loanId: loanId, extendedExpirationDate: extendedExpirationDate });
    }


    /*----------------------------------------------------------*|
    |*  # GET LOAN                                              *|
    |*----------------------------------------------------------*/

    /**
     * @notice Return a LOAN data struct associated with a loan id.
     * @param loanId Id of a loan in question.
     * @return loan LOAN data struct or empty struct if the LOAN doesn't exist.
     */
    function getLOAN(uint256 loanId) external view returns (LOAN memory loan) {
        loan = LOANs[loanId];
        loan.status = _getLOANStatus(loanId);
    }

    /**
     * @notice Return a LOAN status associated with a loan id.
     * @param loanId Id of a loan in question.
     * @return status LOAN status.
     */
    function _getLOANStatus(uint256 loanId) private view returns (uint8) {
        LOAN storage loan = LOANs[loanId];
        return (loan.status == 2 && loan.expiration <= block.timestamp) ? 4 : loan.status;
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
        // - status, expiration
        // Status is updated for expired loans based on block.timestamp.
        // Others don't have to be part of the state fingerprint as it does not act as a token identification.
        return keccak256(abi.encode(
            _getLOANStatus(tokenId),
            loan.expiration
        ));
    }

}
