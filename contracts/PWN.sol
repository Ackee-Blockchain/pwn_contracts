pragma abicoder v2;
pragma solidity ^0.8.0;

import "./MultiToken.sol";
import "./PWNVault.sol";
import "./PWNDeed.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PWN is Ownable {

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    using MultiToken for MultiToken.Asset;

    PWNDeed public token;
    PWNVault public vault;

    uint256 public minDuration = 0;

    /*----------------------------------------------------------*|
    |*  # EVENTS & ERRORS DEFINITIONS                           *|
    |*----------------------------------------------------------*/

    event NewDeed(uint8 cat, uint256 id, uint256 amount, address indexed tokenAddress, uint256 expiration, uint256 indexed did);
    event NewOffer(uint8 cat, uint256 amount, address tokenAddress, address indexed lender, uint256 toBePaid, uint256 indexed did, bytes32 offer);
    event DeedRevoked(uint256 did);
    event OfferRevoked(bytes32 offer);
    event OfferAccepted(uint256 did, bytes32 offer);
    event PaidBack(uint256 did, bytes32 offer);
    event DeedClaimed(uint256 did);
    event MinDurationChange(uint256 minDuration);


    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR & FUNCTIONS                               *|
    |*----------------------------------------------------------*/

    /**
     * Constructor
     * @dev establishes a connection with other pre-deployed components
     * @dev for the set up to work both PWNDeed & PWNVault contracts have to called via `.setPWN(PWN.address)`
     * @param _PWND Address of the PWNDeed contract - defines Deed tokens
     * @param _PWNV Address of the PWNVault contract - holds assets
     */
    constructor(
        address _PWND,
        address _PWNV
    )
    Ownable()
    {
        token = PWNDeed(_PWND);
        vault = PWNVault(_PWNV);
    }

    /**
     * newDeed - sets & locks collateral
     * @dev for UI integrations is this the function enabling creation of a new Deed token
     * @dev Deed status is set to 1
     * @param _cat Category of the asset - see { MultiToken.sol }
     * @param _id ID of an ERC721 or ERC1155 token || 0 in case the token doesn't have IDs
     * @param _amount Amount of an ERC20 or ERC1155 token || 0 in case of NFTs
     * @param _tokenAddress Address of the asset contract
     * @param _expiration Unix time stamp in !! seconds !! (not miliseconds returned by JS)
     * @return a Deed ID of the newly created Deed
     */
    function newDeed(
        uint8 _cat,
        uint256 _id,
        uint256 _amount,
        address _tokenAddress,
        uint256 _expiration
    ) external returns (uint256) {
        require(_cat < 3, "Unknown asset type");
        require(_expiration > (block.timestamp + minDuration));

        uint256 did = token.mint(_cat, _id, _amount, _tokenAddress, _expiration, msg.sender);
        vault.push(token.getDeedAsset(did));
        token.changeStatus(1, did);

        emit NewDeed(_cat, _id, _amount, _tokenAddress, _expiration, did);
        return did;
    }

    /**
     * revokeDeed
     * @dev through this function the borrower can delete the Deed token given no offer was accepted
     * @param _did Deed ID specifying the concrete Deed
     */
    function revokeDeed(
        uint256 _did
    ) external {
        require(msg.sender == token.getBorrower(_did), "The deed doesn't belong to the caller");
        require(token.getDeedStatus(_did) == 1, "Deed can't be revoked at this stage");

        vault.pull(token.getDeedAsset(_did), msg.sender);
        token.burn(_did, msg.sender);
        emit DeedRevoked(_did);
    }

    /**
     * makeOffer
     * @dev this is the function used by lenders to cast their offers
     * @dev this function doesn't assume the asset is approved yet for PWNVault
     * @dev this function requires lender to have a sufficient balance
     * @param _cat Category of the asset - see { MultiToken.sol }
     * @param _amount Amount of an ERC20 or ERC1155 token to be offered as credit
     * @param _tokenAddress Address of the asset contract
     * @param _did ID of the Deed the offer should be bound to
     * @param _toBePaid Amount to be paid back by the borrower
     * @return a hash of the newly created offer
     */
    function makeOffer(
        uint8 _cat,
        uint256 _amount,
        address _tokenAddress,
        uint256 _did,
        uint256 _toBePaid
    ) external returns (bytes32) {
        require(_cat < 3, "Unknown asset type");
        require(token.getDeedStatus(_did) == 1, "Deed not accepting offers");

        bytes32 offer = token.setOffer(_cat, _amount, _tokenAddress, msg.sender, _did, _toBePaid);
        emit NewOffer(_cat, _amount, _tokenAddress,  msg.sender, _toBePaid, _did, offer);

        return offer;
    }

    /**
     * revokeOffer
     * @dev this is the function lenders can use to remove their offers on Deeds they are in the stage of getting offers
     * @param _offer Identifier of the offer to be revoked
     */
    function revokeOffer(
        bytes32 _offer
    ) external {
        require(token.getLender(_offer) == msg.sender, "This address didn't create the offer");
        require(token.getDeedStatus(token.getDeedID(_offer)) == 1, "Can only remove offers from open Deeds");
        token.deleteOffer(_offer);
        emit OfferRevoked(_offer);
    }

    /**
     * acceptOffer
     * @dev through this function a borrower can accept an existing offer
     * @dev a UI should do an off-chain balance check on the lender side to make sure the call won't throw
     * @dev Deed status is set to 2
     * @param _offer Identifier of the offer to be accepted
     * @return true if successful
     */
    function acceptOffer(
        bytes32 _offer
    ) external returns (bool) {
        uint256 did = token.getDeedID(_offer);
        require(msg.sender == token.getBorrower(did), "The deed doesn't belong to the caller");
        require(token.getDeedStatus(did) == 1, "Deed can't accept more offers");

        token.setCredit(did, _offer);
        token.changeStatus(2, did);

        address lender = token.getLender(_offer);
        vault.pullProxy(token.getOfferAsset(_offer), lender, msg.sender);

        MultiToken.Asset memory deed;
        deed.cat = 2;
        deed.id = did;
        deed.tokenAddress = address(token);

        vault.pullProxy(deed, msg.sender, lender);
        emit OfferAccepted(did, _offer);

        return true;
    }

    /**
     * payBack
     * @dev the borrower can pay back the funds through this function
     * @dev the function assumes the asset (and amount to be paid back) to be returned is approved for PWNVault
     * @dev the function assumes the borrower has the full amount to be paid back in their account
     * @param _did Deed ID of the deed being paid back
     * @return true if successful
     */
    function payBack(uint256 _did) external returns (bool) {
        require(token.getDeedStatus(_did) == 2, "Deed doesn't have an accepted offer to be paid back");

        token.changeStatus(3, _did);

        bytes32 offer = token.getAcceptedOffer(_did);
        MultiToken.Asset memory credit = token.getOfferAsset(offer);
        credit.amount = token.toBePaid(offer);               //override the num of credit given

        vault.pull(token.getDeedAsset(_did), token.getBorrower(_did));
        vault.push(credit);

        emit PaidBack(_did, offer);
        return true;
    }

    /**
     * claim Deed
     * @dev The current Deed owner can call this function if the Deed is expired or payed back
     * @param _did Deed ID of the deed to be claimed
     * @return true if successful
     */
    function claimDeed(uint256 _did) external returns (bool) {
        require(token.balanceOf(msg.sender, _did) == 1, "Caller is not the deed owner");
        require(token.getDeedStatus(_did) >= 3, "Deed can't be claimed yet");

        if (token.getDeedStatus(_did) == 3) {
            bytes32 offer = token.getAcceptedOffer(_did);
            MultiToken.Asset memory credit = token.getOfferAsset(offer);
            credit.amount = token.toBePaid(offer);

            vault.pull(credit, msg.sender);
        } else if (token.getDeedStatus(_did) == 4) {
            vault.pull(token.getDeedAsset(_did), msg.sender);
        }

        emit DeedClaimed(_did);
        token.burn(_did, msg.sender);
        return true;
    }

    /*----------------------------------------------------------*|
    |*  ## SETUP FUNCTIONS                                      *|
    |*----------------------------------------------------------*/

    /**
     * changeMinDuration
     * @dev this function sets a minimal time buffer requirement to the expiration time
     * @param _newMinDuration New min expiration duration
     */
    function changeMinDuration(uint256 _newMinDuration) external onlyOwner {
        minDuration = _newMinDuration;
        emit MinDurationChange(_newMinDuration);
    }
}
