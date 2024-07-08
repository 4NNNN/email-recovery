// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { EmailAccountRecovery } from
    "ether-email-auth/packages/contracts/src/EmailAccountRecovery.sol";
import { IEmailRecoveryManager } from "./interfaces/IEmailRecoveryManager.sol";
import { IEmailRecoverySubjectHandler } from "./interfaces/IEmailRecoverySubjectHandler.sol";
import { IEmailRecoveryModule } from "./interfaces/IEmailRecoveryModule.sol";
import {
    EnumerableGuardianMap,
    GuardianStorage,
    GuardianStatus
} from "./libraries/EnumerableGuardianMap.sol";
import { GuardianUtils } from "./libraries/GuardianUtils.sol";

/**
 * @title EmailRecoveryManager
 * @notice Provides a mechanism for account recovery using email guardians
 * @dev The underlying EmailAccountRecovery contract provides some base logic for deploying
 * guardian contracts and handling email verification.
 *
 * This contract defines a default implementation for email-based recovery. It is designed to
 * provide the core logic for email based account recovery that can be used across different account
 * implementations.
 *
 * EmailRecoveryManager relies on a dedicated recovery module to execute a recovery attempt. This
 * (EmailRecoveryManager) contract defines "what a valid recovery attempt is for an account", and
 * the recovery module defines “how that recovery attempt is executed on the account”. A
 * specific email subject handler is also accociated with a recovery manager. A subject handler
 * defines and validates the recovery email subjects. Developers can write their own subject
 * handlers to make specifc subjects for recovering modules
 */
contract EmailRecoveryManager is EmailAccountRecovery, Initializable, IEmailRecoveryManager {
    using GuardianUtils for mapping(address => GuardianConfig);
    using GuardianUtils for mapping(address => EnumerableGuardianMap.AddressToGuardianMap);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    CONSTANTS & STORAGE                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * Minimum required time window between when a recovery attempt becomes valid and when it
     * becomes invalid
     */
    uint256 public constant MINIMUM_RECOVERY_WINDOW = 2 days;

    /**
     * The subject handler that returns and validates the subject templates
     */
    address public immutable subjectHandler;

    /**
     * The recovery module that is responsible for recovering an account
     */
    address public emailRecoveryModule;

    /**
     * Deployer address stored to prevent frontrunning at initialization
     */
    address private deployer;

    /**
     * Account address to recovery config
     */
    mapping(address account => RecoveryConfig recoveryConfig) internal recoveryConfigs;

    /**
     * Account address to recovery request
     */
    mapping(address account => RecoveryRequest recoveryRequest) internal recoveryRequests;

    /**
     * Account to guardian config
     */
    mapping(address account => GuardianConfig guardianConfig) internal guardianConfigs;

    /**
     * Account address to guardian address to guardian storage
     */
    mapping(address account => EnumerableGuardianMap.AddressToGuardianMap guardian) internal
        guardiansStorage;

    constructor(
        address _verifier,
        address _dkimRegistry,
        address _emailAuthImpl,
        address _subjectHandler
    ) {
        verifierAddr = _verifier;
        dkimAddr = _dkimRegistry;
        emailAuthImplementationAddr = _emailAuthImpl;
        subjectHandler = _subjectHandler;
        if (_subjectHandler == address(0)) {
            revert InvalidSubjectHandler();
        }
        deployer = msg.sender;
    }

    function initialize(address _emailRecoveryModule) external initializer {
        if (msg.sender != deployer) {
            revert InitializerNotDeployer();
        }
        if (_emailRecoveryModule == address(0)) {
            revert InvalidRecoveryModule();
        }
        emailRecoveryModule = _emailRecoveryModule;
    }

    /**
     * @notice Modifier to check recovery status. Reverts if recovery is in process for the account
     */
    modifier onlyWhenNotRecovering() {
        if (recoveryRequests[msg.sender].currentWeight > 0) {
            revert RecoveryInProcess();
        }
        _;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*       RECOVERY CONFIG, REQUEST AND TEMPLATE GETTERS        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Retrieves the recovery configuration for a given account
     * @param account The address of the account for which the recovery configuration is being
     * retrieved
     * @return RecoveryConfig The recovery configuration for the specified account
     */
    function getRecoveryConfig(address account) external view returns (RecoveryConfig memory) {
        return recoveryConfigs[account];
    }

    /**
     * @notice Retrieves the recovery request details for a given account
     * @param account The address of the account for which the recovery request details are being
     * retrieved
     * @return RecoveryRequest The recovery request details for the specified account
     */
    function getRecoveryRequest(address account) external view returns (RecoveryRequest memory) {
        return recoveryRequests[account];
    }

    /**
     * @notice Returns a two-dimensional array of strings representing the subject templates for an
     * acceptance by a new guardian.
     * @dev This is retrieved from the associated subject handler. Developers can write their own
     * subject handlers, this is useful for account implementations which require different data in
     * the subject or if the email should be in a language that is not English.
     * @return string[][] A two-dimensional array of strings, where each inner array represents a
     * set of fixed strings and matchers for a subject template.
     */
    function acceptanceSubjectTemplates() public view override returns (string[][] memory) {
        return IEmailRecoverySubjectHandler(subjectHandler).acceptanceSubjectTemplates();
    }

    /**
     * @notice Returns a two-dimensional array of strings representing the subject templates for
     * email recovery.
     * @dev This is retrieved from the associated subject handler. Developers can write their own
     * subject handlers, this is useful for account implementations which require different data in
     * the subject or if the email should be in a language that is not English.
     * @return string[][] A two-dimensional array of strings, where each inner array represents a
     * set of fixed strings and matchers for a subject template.
     */
    function recoverySubjectTemplates() public view override returns (string[][] memory) {
        return IEmailRecoverySubjectHandler(subjectHandler).recoverySubjectTemplates();
    }

    /**
     * @notice Extracts the account address to be recovered from the subject parameters of an
     * acceptance email.
     * @dev This is retrieved from the associated subject handler.
     * @param subjectParams The subject parameters of the acceptance email.
     * @param templateIdx The index of the acceptance subject template.
     */
    function extractRecoveredAccountFromAcceptanceSubject(
        bytes[] memory subjectParams,
        uint256 templateIdx
    )
        public
        view
        override
        returns (address)
    {
        return IEmailRecoverySubjectHandler(subjectHandler)
            .extractRecoveredAccountFromAcceptanceSubject(subjectParams, templateIdx);
    }

    /**
     * @notice Extracts the account address to be recovered from the subject parameters of a
     * recovery email.
     * @dev This is retrieved from the associated subject handler.
     * @param subjectParams The subject parameters of the recovery email.
     * @param templateIdx The index of the recovery subject template.
     */
    function extractRecoveredAccountFromRecoverySubject(
        bytes[] memory subjectParams,
        uint256 templateIdx
    )
        public
        view
        override
        returns (address)
    {
        return IEmailRecoverySubjectHandler(subjectHandler)
            .extractRecoveredAccountFromRecoverySubject(subjectParams, templateIdx);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     CONFIGURE RECOVERY                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Configures recovery for the caller's account. This is the first core function
     * that must be called during the end-to-end recovery flow
     * @dev Can only be called once for configuration. Sets up the guardians, and validates config
     * parameters, ensuring that no recovery is in process. It is possible to configure guardians at
     * a later stage if neccessary
     * @param guardians An array of guardian addresses
     * @param weights An array of weights corresponding to each guardian
     * @param threshold The threshold weight required for recovery
     * @param delay The delay period before recovery can be executed
     * @param expiry The expiry time after which the recovery attempt is invalid
     */
    function configureRecovery(
        address[] memory guardians,
        uint256[] memory weights,
        uint256 threshold,
        uint256 delay,
        uint256 expiry
    )
        external
    {
        address account = msg.sender;

        // Threshold can only be 0 at initialization.
        // Check ensures that setup function can only be called once.
        if (guardianConfigs[account].threshold > 0) {
            revert SetupAlreadyCalled();
        }

        if (!IEmailRecoveryModule(emailRecoveryModule).isAuthorizedToRecover(account)) {
            revert RecoveryModuleNotAuthorized();
        }

        // Allow recovery configuration without configuring guardians
        if (guardians.length == 0 && weights.length == 0 && threshold == 0) {
            guardianConfigs[account].initialized = true;
        } else {
            setupGuardians(account, guardians, weights, threshold);
        }

        RecoveryConfig memory recoveryConfig = RecoveryConfig(delay, expiry);
        updateRecoveryConfig(recoveryConfig);

        emit RecoveryConfigured(account, guardians.length);
    }

    /**
     * @notice Updates and validates the recovery configuration for the caller's account
     * @dev Validates and sets the new recovery configuration for the caller's account, ensuring
     * that no recovery is in process.
     * @param recoveryConfig The new recovery configuration to be set for the caller's account
     */
    function updateRecoveryConfig(RecoveryConfig memory recoveryConfig)
        public
        onlyWhenNotRecovering
    {
        address account = msg.sender;

        if (!guardianConfigs[account].initialized) {
            revert AccountNotConfigured();
        }
        if (recoveryConfig.delay > recoveryConfig.expiry) {
            revert DelayMoreThanExpiry();
        }
        if (recoveryConfig.expiry - recoveryConfig.delay < MINIMUM_RECOVERY_WINDOW) {
            revert RecoveryWindowTooShort();
        }

        recoveryConfigs[account] = recoveryConfig;

        emit RecoveryConfigUpdated(account, recoveryConfig.delay, recoveryConfig.expiry);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     HANDLE ACCEPTANCE                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Accepts a guardian for the specified account. This is the second core function
     * that must be called during the end-to-end recovery flow
     * @dev Called once per guardian added. Although this adds an extra step to recovery, this
     * acceptance flow is an important security feature to ensure that no typos are made when adding
     * a guardian, and that the guardian is in control of the specified email address. Called as
     * part of handleAcceptance in EmailAccountRecovery
     * @param guardian The address of the guardian to be accepted
     * @param templateIdx The index of the template used for acceptance
     * @param subjectParams An array of bytes containing the subject parameters
     */
    function acceptGuardian(
        address guardian,
        uint256 templateIdx,
        bytes[] memory subjectParams,
        bytes32
    )
        internal
        override
    {
        if (templateIdx != 0) {
            revert InvalidTemplateIndex();
        }

        address account = IEmailRecoverySubjectHandler(subjectHandler).validateAcceptanceSubject(
            templateIdx, subjectParams
        );

        if (recoveryRequests[account].currentWeight > 0) {
            revert RecoveryInProcess();
        }

        if (!IEmailRecoveryModule(emailRecoveryModule).isAuthorizedToRecover(account)) {
            revert RecoveryModuleNotAuthorized();
        }

        // This check ensures GuardianStatus is correct and also implicitly that the
        // account in email is a valid account
        GuardianStorage memory guardianStorage = getGuardian(account, guardian);
        if (guardianStorage.status != GuardianStatus.REQUESTED) {
            revert InvalidGuardianStatus(guardianStorage.status, GuardianStatus.REQUESTED);
        }

        guardiansStorage.updateGuardianStatus(account, guardian, GuardianStatus.ACCEPTED);

        emit GuardianAccepted(account, guardian);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      HANDLE RECOVERY                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Processes a recovery request for a given account. This is the third core function
     * that must be called during the end-to-end recovery flow
     * @dev Called once per guardian until the threshold is reached
     * @param guardian The address of the guardian initiating the recovery
     * @param templateIdx The index of the template used for the recovery request
     * @param subjectParams An array of bytes containing the subject parameters
     */
    function processRecovery(
        address guardian,
        uint256 templateIdx,
        bytes[] memory subjectParams,
        bytes32
    )
        internal
        override
    {
        if (templateIdx != 0) {
            revert InvalidTemplateIndex();
        }

        (address account, bytes32 calldataHash) = IEmailRecoverySubjectHandler(subjectHandler)
            .validateRecoverySubject(templateIdx, subjectParams, address(this));

        if (!IEmailRecoveryModule(emailRecoveryModule).isAuthorizedToRecover(account)) {
            revert RecoveryModuleNotAuthorized();
        }

        // This check ensures GuardianStatus is correct and also implicitly that the
        // account in email is a valid account
        GuardianStorage memory guardianStorage = getGuardian(account, guardian);
        if (guardianStorage.status != GuardianStatus.ACCEPTED) {
            revert InvalidGuardianStatus(guardianStorage.status, GuardianStatus.ACCEPTED);
        }

        RecoveryRequest storage recoveryRequest = recoveryRequests[account];

        recoveryRequest.currentWeight += guardianStorage.weight;

        uint256 threshold = guardianConfigs[account].threshold;
        if (recoveryRequest.currentWeight >= threshold) {
            uint256 executeAfter = block.timestamp + recoveryConfigs[account].delay;
            uint256 executeBefore = block.timestamp + recoveryConfigs[account].expiry;

            recoveryRequest.executeAfter = executeAfter;
            recoveryRequest.executeBefore = executeBefore;
            recoveryRequest.calldataHash = calldataHash;

            emit RecoveryProcessed(account, executeAfter, executeBefore);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     COMPLETE RECOVERY                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Completes the recovery process for a given account. This is the forth and final
     * core function that must be called during the end-to-end recovery flow. Can be called by
     * anyone.
     * @dev Validates the recovery request by checking the total weight, that the delay has passed,
     * and the request has not expired. Triggers the recovery module to perform the recovery. The
     * recovery module trusts that this contract has validated the recovery attempt. This function
     * deletes the recovery request but recovery config state is maintained so future recovery
     * requests can be made without having to reconfigure everything
     * @param account The address of the account for which the recovery is being completed
     * @param recoveryCalldata The calldata that is passed to recover the validator
     */
    function completeRecovery(address account, bytes memory recoveryCalldata) public override {
        if (account == address(0)) {
            revert InvalidAccountAddress();
        }
        RecoveryRequest memory recoveryRequest = recoveryRequests[account];

        uint256 threshold = guardianConfigs[account].threshold;
        if (threshold == 0) {
            revert NoRecoveryConfigured();
        }

        if (recoveryRequest.currentWeight < threshold) {
            revert NotEnoughApprovals();
        }

        if (block.timestamp < recoveryRequest.executeAfter) {
            revert DelayNotPassed();
        }

        if (block.timestamp >= recoveryRequest.executeBefore) {
            revert RecoveryRequestExpired();
        }

        bytes32 calldataHash = keccak256(recoveryCalldata);
        if (calldataHash != recoveryRequest.calldataHash) {
            revert InvalidCalldataHash();
        }

        delete recoveryRequests[account];

        IEmailRecoveryModule(emailRecoveryModule).recover(account, recoveryCalldata);

        emit RecoveryCompleted(account);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    CANCEL/DE-INIT LOGIC                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Cancels the recovery request for the caller's account
     * @dev Deletes the current recovery request associated with the caller's account
     */
    function cancelRecovery() external virtual {
        delete recoveryRequests[msg.sender];
        emit RecoveryCancelled(msg.sender);
    }

    /**
     * @notice Removes all state related to an account. Must be called from a configured recovery
     * module
     * @dev In order to prevent unexpected behaviour when reinstalling account modules, the module
     * should be deinitialized. This should include remove state accociated with an account.
     * @param account The account to delete state for
     */
    function deInitRecoveryFromModule(address account) external {
        if (emailRecoveryModule != msg.sender) {
            revert NotRecoveryModule();
        }

        if (recoveryRequests[account].currentWeight > 0) {
            revert RecoveryInProcess();
        }

        delete recoveryConfigs[account];
        delete recoveryRequests[account];

        guardiansStorage.removeAllGuardians(account);
        delete guardianConfigs[account];

        emit RecoveryDeInitialized(account);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       GUARDIAN LOGIC                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Retrieves the guardian configuration for a given account
     * @param account The address of the account for which the guardian configuration is being
     * retrieved
     * @return GuardianConfig The guardian configuration for the specified account
     */
    function getGuardianConfig(address account) external view returns (GuardianConfig memory) {
        return guardianConfigs[account];
    }

    /**
     * @notice Retrieves the guardian storage details for a given guardian and account
     * @param account The address of the account associated with the guardian
     * @param guardian The address of the guardian
     * @return GuardianStorage The guardian storage details for the specified guardian and account
     */
    function getGuardian(
        address account,
        address guardian
    )
        public
        view
        returns (GuardianStorage memory)
    {
        return guardiansStorage.getGuardianStorage(account, guardian);
    }

    /**
     * @notice Sets up guardians for a given account with specified weights and threshold
     * @dev This function can only be called once and ensures the guardians, weights, and threshold
     * are correctly configured
     * @param account The address of the account for which guardians are being set up
     * @param guardians An array of guardian addresses
     * @param weights An array of weights corresponding to each guardian
     * @param threshold The threshold weight required for guardians to approve recovery attempts
     */
    function setupGuardians(
        address account,
        address[] memory guardians,
        uint256[] memory weights,
        uint256 threshold
    )
        internal
    {
        guardianConfigs.setupGuardians(guardiansStorage, account, guardians, weights, threshold);
    }

    /**
     * @notice Adds a guardian for the caller's account with a specified weight
     * @dev This function can only be called by the account associated with the guardian and only if
     * no recovery is in process
     * @param guardian The address of the guardian to be added
     * @param weight The weight assigned to the guardian
     */
    function addGuardian(address guardian, uint256 weight) external onlyWhenNotRecovering {
        guardiansStorage.addGuardian(guardianConfigs, msg.sender, guardian, weight);
    }

    /**
     * @notice Removes a guardian for the caller's account
     * @dev This function can only be called by the account associated with the guardian and only if
     * no recovery is in process
     * @param guardian The address of the guardian to be removed
     */
    function removeGuardian(address guardian) external onlyWhenNotRecovering {
        guardiansStorage.removeGuardian(guardianConfigs, msg.sender, guardian);
    }

    /**
     * @notice Changes the threshold for guardian approvals for the caller's account
     * @dev This function can only be called by the account associated with the guardian config and
     * only if no recovery is in process
     * @param threshold The new threshold for guardian approvals
     */
    function changeThreshold(uint256 threshold) external onlyWhenNotRecovering {
        guardianConfigs.changeThreshold(msg.sender, threshold);
    }
}
