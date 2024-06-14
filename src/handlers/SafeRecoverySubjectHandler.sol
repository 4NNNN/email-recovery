// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IEmailRecoverySubjectHandler } from "../interfaces/IEmailRecoverySubjectHandler.sol";
import { IEmailRecoveryManager } from "../interfaces/IEmailRecoveryManager.sol";
import { ISafe } from "../interfaces/ISafe.sol";

/**
 * Handler contract that defines subject templates and how to validate them
 * This is a custom subject handler that will work with Safes and defines custom validation.
 */
contract SafeRecoverySubjectHandler is IEmailRecoverySubjectHandler {
    using Strings for uint256;

    error InvalidSubjectParams();
    error InvalidOldOwner();
    error InvalidNewOwner();
    error InvalidRecoveryModule();

    constructor() { }

    function acceptanceSubjectTemplates() public pure returns (string[][] memory) {
        string[][] memory templates = new string[][](1);
        templates[0] = new string[](5);
        templates[0][0] = "Accept";
        templates[0][1] = "guardian";
        templates[0][2] = "request";
        templates[0][3] = "for";
        templates[0][4] = "{ethAddr}";
        return templates;
    }

    function recoverySubjectTemplates() public pure returns (string[][] memory) {
        string[][] memory templates = new string[][](1);
        templates[0] = new string[](15);
        templates[0][0] = "Recover";
        templates[0][1] = "account";
        templates[0][2] = "{ethAddr}";
        templates[0][3] = "from";
        templates[0][4] = "old";
        templates[0][5] = "owner";
        templates[0][6] = "{ethAddr}";
        templates[0][7] = "to";
        templates[0][8] = "new";
        templates[0][9] = "owner";
        templates[0][10] = "{ethAddr}";
        templates[0][11] = "using";
        templates[0][12] = "recovery";
        templates[0][13] = "module";
        templates[0][14] = "{ethAddr}";
        return templates;
    }

    function validateAcceptanceSubject(
        uint256 templateIdx,
        bytes[] calldata subjectParams
    )
        external
        pure
        returns (address)
    {
        if (subjectParams.length != 1) revert InvalidSubjectParams();

        // The GuardianStatus check in acceptGuardian implicitly
        // validates the account, so no need to re-validate here
        address accountInEmail = abi.decode(subjectParams[0], (address));

        return accountInEmail;
    }

    function validateRecoverySubject(
        uint256 templateIdx,
        bytes[] calldata subjectParams,
        address recoveryManager
    )
        public
        view
        returns (address, string memory)
    {
        if (subjectParams.length != 4) {
            revert InvalidSubjectParams();
        }

        address accountInEmail = abi.decode(subjectParams[0], (address));
        address oldOwnerInEmail = abi.decode(subjectParams[1], (address));
        address newOwnerInEmail = abi.decode(subjectParams[2], (address));
        address recoveryModuleInEmail = abi.decode(subjectParams[3], (address));

        bool isOwner = ISafe(accountInEmail).isOwner(oldOwnerInEmail);
        if (!isOwner) {
            revert InvalidOldOwner();
        }

        if (newOwnerInEmail == address(0)) {
            revert InvalidNewOwner();
        }

        // Even though someone could use a malicious contract as the recoveryManager argument, it
        // does not matter in this case as this
        address expectedRecoveryModule =
            IEmailRecoveryManager(recoveryManager).getRecoveryConfig(accountInEmail).recoveryModule;
        if (recoveryModuleInEmail == address(0) || recoveryModuleInEmail != expectedRecoveryModule)
        {
            revert InvalidRecoveryModule();
        }

        address previousOwnerInLinkedList =
            getPreviousOwnerInLinkedList(accountInEmail, oldOwnerInEmail);
        string memory functionSignature = "swapOwner(address,address,address)";
        bytes memory recoveryCallData = abi.encodeWithSignature(
            functionSignature, previousOwnerInLinkedList, oldOwnerInEmail, newOwnerInEmail
        );
        bytes32 calldataHash = keccak256(recoveryCallData);
        string memory calldataHashString = uint256(calldataHash).toHexString(32);

        return (accountInEmail, calldataHashString);
    }

    function getPreviousOwnerInLinkedList(
        address safe,
        address oldOwner
    )
        internal
        view
        returns (address)
    {
        address[] memory owners = ISafe(safe).getOwners();
        uint256 length = owners.length;

        uint256 oldOwnerIndex;
        for (uint256 i; i < length; i++) {
            if (owners[i] == oldOwner) {
                oldOwnerIndex = i;
                break;
            }
        }
        address sentinelOwner = address(0x1);
        return oldOwnerIndex == 0 ? sentinelOwner : owners[oldOwnerIndex - 1];
    }
}
