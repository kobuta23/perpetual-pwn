// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.13;

import "@pwnfinance/multitoken/contracts/MultiToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@superfluid-finance/ethereum-contracts@dev/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";
import "@superfluid-finance/ethereum-contracts@dev/contracts/interfaces/superfluid/ISuperToken.sol";
import "@superfluid-finance/ethereum-contracts@dev/contracts/interfaces/superfluid/ISuperfluid.sol";
import "@superfluid-finance/ethereum-contracts@dev/contracts/apps/CFAv1Library.sol";

contract PWNLOAN is ERC1155, Ownable {

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    /**
     * Necessary msg.sender for all LOAN related manipulations
     */
    address public PWN;

    /**
     * Incremental LOAN ID counter
     */
    uint256 public id;

    /**
     * EIP-1271 valid signature magic value
     */
    bytes4 constant internal EIP1271_VALID_SIGNATURE = 0x1626ba7e;

    /**
     * EIP-712 offer struct type hash
     */
    bytes32 constant internal OFFER_TYPEHASH = keccak256(
        "Offer(address collateralAddress,uint8 collateralCategory,uint256 collateralAmount,uint256 collateralId,address loanAssetAddress,uint256 loanAmount,uint256 loanYield,uint32 duration,uint40 expiration,address lender,bytes32 nonce)"
    );

    //Superfluid

    using CFAv1Library for CFAv1Library.InitData;
    CFAv1Library.InitData public cfaV1;

    /**
     * Construct defining a LOAN which is an acronym for: ... (TODO)
     * @param status 0 == none/dead || 2 == running/accepted offer || 3 == paid back || 4 == expired
     * @param borrower Address of the borrower - stays the same for entire lifespan of the token
     * @param duration Loan duration in seconds
     * @param expiration Unix timestamp (in seconds) setting up the default deadline
     * @param collateral Asset used as a loan collateral. Consisting of another `Asset` struct defined in the MultiToken library
     * @param asset Asset to be borrowed by lender to borrower. Consisting of another `Asset` struct defined in the MultiToken library
     * @param loanRepayAmount Amount of LOAN asset to be repaid
     */
    struct LOAN {
        uint8 status;
        address borrower;
        uint32 duration;
        uint40 expiration;
        MultiToken.Asset collateral;
        MultiToken.Asset asset;
        uint256 loanRepayAmount;
        int96 interestByTheSecond; // flowrate of the stream
    }

    /**
     * Construct defining an Offer
     * @param collateralAddress Address of an asset used as a collateral
     * @param collateralCategory Category of an asset used as a collateral (0 == ERC20, 1 == ERC721, 2 == ERC1155)
     * @param collateralAmount Amount of tokens used as a collateral, in case of ERC721 should be 1
     * @param collateralId Token id of an asset used as a collateral, in case of ERC20 should be 0
     * @param loanAssetAddress Address of an asset which is lended to borrower
     * @param loanAmount Amount of tokens which is offered as a loan to borrower
     * @param loanYield Amount of tokens which acts as a lenders loan interest. Borrower has to pay back borrowed amount + yield.
     * @param duration Loan duration in seconds
     * @param expiration Offer expiration timestamp in seconds
     * @param lender Address of a lender. This address has to sign an offer to be valid.
     * @param nonce Additional value to enable identical offers in time. Without it, it would be impossible to make again offer, which was once revoked.
     */
    struct Offer {
        address collateralAddress;
        MultiToken.Category collateralCategory;
        uint256 collateralAmount;
        uint256 collateralId;
        address loanAssetAddress;
        uint256 loanAmount;
        uint256 loanYield; // use this for interestByTheSecond
        uint32 duration;
        uint40 expiration;
        address lender;
        bytes32 nonce;
    }

    /**
     * Mapping of all LOAN data by loan id
     */
    mapping (uint256 => LOAN) public LOANs;

    /**
     * Mapping of revoked offers by offer struct typed hash
     */
    mapping (bytes32 => bool) public revokedOffers;

    /*----------------------------------------------------------*|
    |*  # EVENTS & ERRORS DEFINITIONS                           *|
    |*----------------------------------------------------------*/

    event LOANCreated(uint256 indexed loanId, address indexed lender, bytes32 indexed offerHash);
    event OfferRevoked(bytes32 indexed offerHash);
    event PaidBack(uint256 loanId);
    event LOANClaimed(uint256 loanId);

    /*----------------------------------------------------------*|
    |*  # MODIFIERS                                             *|
    |*----------------------------------------------------------*/

    modifier onlyPWN() {
        require(msg.sender == PWN, "Caller is not the PWN");
        _;
    }

    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR & FUNCTIONS                               *|
    |*----------------------------------------------------------*/

    /*
     * PWN LOAN constructor
     * @dev Creates the PWN LOAN token contract - ERC1155 with extra use case specific features
     * @dev Once the PWN contract is set, you'll have to call `this.setPWN(PWN.address)` for this contract to work
     * @param _uri Uri to be used for finding the token metadata
     */
    constructor(string memory _uri, ISuperfluid _host) ERC1155(_uri) Ownable() {
        IConstantFlowAgreementV1 cfa = IConstantFlowAgreementV1(
            address(_host.getAgreementClass(keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1")))
        );
        cfaV1 = CFAv1Library.InitData(_host, cfa);
    }

    /**
     * All contracts of this section can only be called by the PWN contract itself - once set via `setPWN(PWN.address)`
     */

    /**
     * revokeOffer
     * @notice Revoke an offer
     * @dev Offer is revoked by lender or when offer is accepted by borrower to prevent accepting it twice
     * @param _offerHash Offer typed struct hash
     * @param _signature Offer typed struct signature
     * @param _sender Address of a message sender (lender)
     */
    function revokeOffer(
        bytes32 _offerHash,
        bytes calldata _signature,
        address _sender
    ) external onlyPWN {
        require(ECDSA.recover(_offerHash, _signature) == _sender, "Sender is not an offer signer");
        require(revokedOffers[_offerHash] == false, "Offer is already revoked or has been accepted");

        revokedOffers[_offerHash] = true;

        emit OfferRevoked(_offerHash);
    }

    /**
     * create
     * @notice Creates the PWN LOAN token - ERC1155 with extra use case specific features from simple offer
     * @dev Contract wallets need to implement EIP-1271 to validate signature on the contract behalf
     * @param _offer Offer struct holding plain offer data
     * @param _signature Offer typed struct signature signed by lender
     * @param _sender Address of a message sender (borrower)
     */
    function create(
        Offer memory _offer,
        bytes memory _signature,
        address _sender
    ) external onlyPWN {
        bytes32 offerHash = keccak256(abi.encodePacked(
            "\x19\x01", _eip712DomainSeparator(), hash(_offer)
        ));

        _checkValidSignature(_offer.lender, offerHash, _signature);
        _checkValidOffer(_offer.expiration, offerHash);

        revokedOffers[offerHash] = true;

        uint256 _id = ++id;

        LOAN storage loan = LOANs[_id];
        loan.status = 2;
        loan.borrower = _sender;
        loan.collateral = MultiToken.Asset(
            _offer.collateralAddress,
            _offer.collateralCategory,
            _offer.collateralAmount,
            _offer.collateralId
        );
        loan.asset = MultiToken.Asset(
            _offer.loanAssetAddress,
            MultiToken.Category.ERC20,
            _offer.loanAmount,
            0
        );
        if(_offer.duration == 0){
            loan.expiration = type(uint40).max;
            loan.interestByTheSecond = int96(uint96(_offer.loanYield)); //FIXME: this casting isn't safe
            loan.loanRepayAmount = _offer.loanAmount;
        }
        else{
            loan.duration = _offer.duration;
            loan.expiration = uint40(block.timestamp) + _offer.duration;
            loan.loanRepayAmount = _offer.loanAmount + _offer.loanYield;
            loan.interestByTheSecond = 0;
        }

        _mint(_offer.lender, _id, 1, "");

        emit LOANCreated(_id, _offer.lender, offerHash);
    }

    function createStream(address _owner) public onlyPWN {
        cfaV1.createFlowByOperator(
            LOANs[id].borrower, 
            _owner, 
            ISuperToken(LOANs[id].asset.assetAddress), 
            LOANs[id].interestByTheSecond
        );
    }

    function closeStream(uint256 _loanId, address _owner) public onlyPWN {
        cfaV1.deleteFlowByOperator(
            LOANs[_loanId].borrower,
            _owner,
            ISuperToken(LOANs[_loanId].asset.assetAddress)
        );
    }

    function getStartTime(LOAN memory loan) private pure returns (uint256){
        return loan.expiration - loan.duration;
    }

    /**
     * repayLoan
     * @notice Function to make proper state transition
     * @param _loanId ID of the LOAN which is paid back
     */
    function repayLoan(uint256 _loanId, address _owner) external onlyPWN {
        require(getStatus(_loanId, _owner) == 2, "Loan is not running and cannot be paid back");

        LOANs[_loanId].status = 3;

        emit PaidBack(_loanId);
    }

    /**
     * claim
     * @notice Function that would set the LOAN to the dead state if the token is in paidBack or expired state
     * @param _loanId ID of the LOAN which is claimed
     * @param _owner Address of the LOAN token owner
     */
    function claim(
        uint256 _loanId,
        address _owner
    ) external onlyPWN {
        require(balanceOf(_owner, _loanId) == 1, "Caller is not the loan owner");
        require(getStatus(_loanId, _owner) >= 3, "Loan can't be claimed yet");

        LOANs[_loanId].status = 0;

        emit LOANClaimed(_loanId);
    }

    /**
     * burn
     * @notice Function that would burn the LOAN token if the token is in dead state
     * @param _loanId ID of the LOAN which is burned
     * @param _owner Address of the LOAN token owner
     */
    function burn(
        uint256 _loanId,
        address _owner
    ) external onlyPWN {
        require(balanceOf(_owner, _loanId) == 1, "Caller is not the loan owner");
        require(LOANs[_loanId].status == 0, "Loan can't be burned at this stage");

        delete LOANs[_loanId];
        _burn(_owner, _loanId, 1);
    }

    /*----------------------------------------------------------*|
    |*  ## VIEW FUNCTIONS                                       *|
    |*----------------------------------------------------------*/

    /**
     * getStatus
     * @dev used in contract calls & status checks and also in UI for elementary loan status categorization
     * @param _loanId LOAN ID checked for status
     * @return a status number
     */
    function getStatus(uint256 _loanId, address _owner) public view returns (uint8) {
        if (LOANs[_loanId].expiration > 0 && LOANs[_loanId].expiration < block.timestamp && LOANs[_loanId].status != 3) {
            return 4;
        } else if (LOANs[_loanId].expiration == type(uint40).max) {
            (uint256 startTime, int96 flowRate,,) = cfaV1.cfa.getFlow(
                ISuperToken(LOANs[_loanId].asset.assetAddress),
                LOANs[_loanId].borrower,
                _owner
            );
            if(startTime == getStartTime(LOANs[_loanId]) && flowRate == LOANs[_loanId].interestByTheSecond) {
                return 2;
            } else {
                return LOANs[_loanId].status == 3 ? 3 : 4;
            }
        } else {
            return LOANs[_loanId].status;
        }
    }

    /**
     * getExpiration
     * @dev utility function to find out exact expiration time of a particular LOAN
     * @dev for simple status check use `this.getStatus(did)` if `status == 4` then LOAN has expired
     * @param _loanId LOAN ID to be checked
     * @return unix time stamp in seconds
     */
    function getExpiration(uint256 _loanId) external view returns (uint40) {
        return LOANs[_loanId].expiration;
    }

    /**
     * getDuration
     * @dev utility function to find out loan duration period of a particular LOAN
     * @param _loanId LOAN ID to be checked
     * @return loan duration period in seconds
     */
    function getDuration(uint256 _loanId) external view returns (uint32) {
        return LOANs[_loanId].duration;
    }

    /**
     * getBorrower
     * @dev utility function to find out a borrower address of a particular LOAN
     * @param _loanId LOAN ID to be checked
     * @return address of the borrower
     */
    function getBorrower(uint256 _loanId) external view returns (address) {
        return LOANs[_loanId].borrower;
    }

    /**
     * getCollateral
     * @dev utility function to find out collateral asset of a particular LOAN
     * @param _loanId LOAN ID to be checked
     * @return Asset construct - for definition see { MultiToken.sol }
     */
    function getCollateral(uint256 _loanId) external view returns (MultiToken.Asset memory) {
        return LOANs[_loanId].collateral;
    }

    /**
     * getLoanAsset
     * @dev utility function to find out loan asset of a particular LOAN
     * @param _loanId LOAN ID to be checked
     * @return Asset construct - for definition see { MultiToken.sol }
     */
    function getLoanAsset(uint256 _loanId) external view returns (MultiToken.Asset memory) {
        return LOANs[_loanId].asset;
    }

    /**
     * getLoanRepayAmount
     * @dev utility function to find out loan repay amount of a particular LOAN
     * @param _loanId LOAN ID to be checked
     * @return Amount of loan asset to be repaid
     */
    function getLoanRepayAmount(uint256 _loanId) external view returns (uint256) {
        return LOANs[_loanId].loanRepayAmount;
    }

    /**
     * isRevoked
     * @dev utility function to find out if offer is revoked
     * @param _offerHash Offer typed struct hash
     * @return True if offer is revoked
     */
    function isRevoked(bytes32 _offerHash) external view returns (bool) {
        return revokedOffers[_offerHash];
    }

    /*--------------------------------*|
    |*  ## SETUP FUNCTIONS            *|
    |*--------------------------------*/

    /**
     * setPWN
     * @dev An essential setup function. Has to be called once PWN contract was deployed
     * @param _address Identifying the PWN contract
     */
    function setPWN(address _address) external onlyOwner {
        PWN = _address;
    }

    /**
     * setUri
     * @dev An non-essential setup function. Can be called to adjust the LOAN token metadata URI
     * @param _newUri setting the new origin of LOAN metadata
     */
    function setUri(string memory _newUri) external onlyOwner {
        _setURI(_newUri);
    }

    /*--------------------------------*|
    |*  ## PRIVATE FUNCTIONS          *|
    |*--------------------------------*/

    /**
     * _eip712DomainSeparator
     * @notice Compose EIP712 domain separator
     * @dev Domain separator is composing to prevent repay attack in case of an Ethereum fork
     */
    function _eip712DomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("PWN")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }

    /**
     * _checkValidSignature
     * @notice
     * @param _lender Address of a lender. This address has to sign an offer to be valid.
     * @param _offerHash Hash of an offer EIP-712 data struct
     * @param _signature Signed offer data
     */
    function _checkValidSignature(
        address _lender,
        bytes32 _offerHash,
        bytes memory _signature
    ) private view {
        if (_lender.code.length > 0) {
            require(IERC1271(_lender).isValidSignature(_offerHash, _signature) == EIP1271_VALID_SIGNATURE, "Signature on behalf of contract is invalid");
        } else {
            require(ECDSA.recover(_offerHash, _signature) == _lender, "Lender address didn't sign the offer");
        }
    }

    /**
     * _checkValidOffer
     * @notice
     * @param _expiration Offer expiration timestamp in seconds
     * @param _offerHash Hash of an offer EIP-712 data struct
     */
    function _checkValidOffer(
        uint40 _expiration,
        bytes32 _offerHash
    ) private view {
        require(_expiration == 0 || block.timestamp < _expiration, "Offer is expired");
        require(revokedOffers[_offerHash] == false, "Offer is revoked or has been accepted");
    }

    /**
     * hash offer
     * @notice Hash offer struct according to EIP-712
     * @param _offer Offer struct to be hashed
     * @return Offer struct hash
     */
    function hash(Offer memory _offer) private pure returns (bytes32) {
        return keccak256(abi.encode(
            OFFER_TYPEHASH,
            _offer.collateralAddress,
            _offer.collateralCategory,
            _offer.collateralAmount,
            _offer.collateralId,
            _offer.loanAssetAddress,
            _offer.loanAmount,
            _offer.loanYield,
            _offer.duration,
            _offer.expiration,
            _offer.lender,
            _offer.nonce
        ));
    }

        /**
     * @dev Hook that is called before any token transfer. This includes minting
     * and burning, as well as batched variants.
     *
     * The same hook is called on both single and batched variants. For single
     * transfers, the length of the `id` and `amount` arrays will be 1.
     *
     * Calling conditions (for each `id` and `amount` pair):
     *
     * - When `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * of token type `id` will be  transferred to `to`.
     * - When `from` is zero, `amount` tokens of token type `id` will be minted
     * for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens of token type `id`
     * will be burned.
     * - `from` and `to` are never both zero.
     * - `ids` and `amounts` have the same, non-zero length.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(
        address ,//operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory ,//amounts,
        bytes memory //data
    ) internal override {
        if(LOANs[ids[0]].expiration == type(uint40).max){
            (,int96 flowRate,,) = cfaV1.cfa.getFlow(ISuperToken(LOANs[ids[0]].asset.assetAddress),LOANs[ids[0]].borrower, from);
            
            // there is a case, where there is already a stream, but it's from a different loan...
            // safer to use "decrease and increase" functions, to take care of the merging... 
            _reduceFlow(LOANs[ids[0]].borrower, from, ISuperToken(LOANs[ids[0]].asset.assetAddress), LOANs[ids[0]].interestByTheSecond);
            if(to!=address(0)){
                if(LOANs[ids[0]].borrower != to) {
                    _increaseFlow(LOANs[ids[0]].borrower, from, ISuperToken(LOANs[ids[0]].asset.assetAddress), LOANs[ids[0]].interestByTheSecond);
                }
                LOANs[ids[0]].duration = uint32(type(uint40).max) - uint32(block.timestamp);
            }
        }
    }
        function _reduceFlow(address _from, address _to, ISuperToken _token, int96 _flowRate) internal {
        if (_to == _from) return;

        (, int96 outFlowRate, , ) = cfaV1.cfa.getFlow(
            _token,
            _from,
            _to
        );

        if (outFlowRate == _flowRate) {
            cfaV1.deleteFlowByOperator(_from, _to, _token);
        } else if (outFlowRate > _flowRate) {
            // reduce the outflow by flowRate;
            // shouldn't overflow, because we just checked that it was bigger.
            cfaV1.updateFlowByOperator(_from, _to, _token, outFlowRate - _flowRate);
        }
        // won't do anything if outFlowRate < flowRate
    }

    //this will increase the flow or create it
    function _increaseFlow(address _from, address _to, ISuperToken _token, int96 _flowRate) internal {
        if (_to == _from) return;

        (, int96 outFlowRate, , ) = cfaV1.cfa.getFlow(
            _token,
            _from,
            _to
        ); //returns 0 if stream doesn't exist
        if (outFlowRate == 0) {
            cfaV1.createFlowByOperator(_from, _to, _token, _flowRate);
        } else {
            // increase the outflow by flowRates[tokenId]
            cfaV1.updateFlowByOperator(_from, _to, _token, outFlowRate + _flowRate);
        }
    }


}