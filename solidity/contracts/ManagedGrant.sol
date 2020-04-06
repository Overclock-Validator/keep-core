pragma solidity ^0.5.4;

import "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";
import "./TokenGrant.sol";

contract ManagedGrant {
    using SafeERC20 for ERC20Burnable;

    ERC20Burnable public token;
    TokenGrant public tokenGrant;
    address public grantManager;
    uint256 public grantId;
    address public grantee;
    address public requestedNewGrantee;

    constructor(
        address _tokenAddress,
        address _tokenGrant,
        address _grantManager,
        uint256 _grantId,
        address _grantee
    ) public {
        token = ERC20Burnable(_tokenAddress);
        tokenGrant = TokenGrant(_tokenGrant);
        grantManager = _grantManager;
        grantId = _grantId;
        grantee = _grantee;
    }

    function requestGranteeReassignment(address _newGrantee) public onlyGrantee {
        require(
            requestedNewGrantee == address(0),
            "Reassignment already requested"
        );
        require(_newGrantee != address(0), "Invalid new grantee address");
        require(_newGrantee != grantee, "Unchanged new grantee address");

        requestedNewGrantee = _newGrantee;
    }

    function confirmGranteeReassignment(address _newGrantee) public onlyManager {
        address _requestedNewGrantee = requestedNewGrantee;
        require(
            _requestedNewGrantee != address(0),
            "No reassignment requested"
        );
        require(
            _requestedNewGrantee == _newGrantee,
            "Reassignment address mismatch"
        );
        grantee = _requestedNewGrantee;
        requestedNewGrantee = address(0);
    }

    function withdraw() public onlyGrantee {
        require(
            requestedNewGrantee == address(0),
            "Can not withdraw with pending reassignment"
        );
        tokenGrant.withdraw(grantId);
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(grantee, amount);
    }

    function stake(
        address _stakingContract,
        uint256 _amount,
        bytes memory _extraData
    ) public onlyGrantee {
        tokenGrant.stake(grantId, _stakingContract, _amount, _extraData);
    }

    function cancelStake(address _operator) public onlyGranteeOr(_operator) {
        tokenGrant.cancelStake(_operator);
    }

    function undelegate(address _operator) public onlyGranteeOr(_operator) {
        tokenGrant.undelegate(_operator);
    }

    function recoverStake(address _operator) public onlyGrantee {
        tokenGrant.recoverStake(_operator);
    }

    modifier onlyGrantee {
        require(
            msg.sender == grantee,
            "Only grantee may perform this action"
        );
        _;
    }

    modifier onlyGranteeOr(address _operator) {
        require(
            msg.sender == grantee || msg.sender == _operator,
            "Only grantee or operator may perform this action"
        );
        _;
    }

    modifier onlyManager {
        require(
            msg.sender == grantManager,
            "Only grantManager may perform this action"
        );
        _;
    }
}
