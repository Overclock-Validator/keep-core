// SPDX-License-Identifier: MIT

pragma solidity ^0.8.6;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./BytesLib.sol";

library DKG {
  using BytesLib for bytes;
  using ECDSA for bytes32;

  /// @dev Size of a group in the threshold relay.
  uint256 public constant groupSize = 64;

  /// @dev Minimum number of group members needed to interact according to the
  ///      protocol to produce a relay entry.
  uint256 public constant groupThreshold = 33;

  /// @dev The minimum number of signatures required to support DKG result.
  ///      This number needs to be at least the same as the signing threshold
  ///      and it is recommended to make it higher than the signing threshold
  ///      to keep a safety margin for in case some members become inactive.
  uint256 public constant signatureThreshold =
    groupThreshold + (groupSize - groupThreshold) / 2;

  /// @notice Time in blocks after which DKG result is complete and ready to be
  //          published by clients.
  uint256 public constant offchainDkgTime = 5 * (1 + 5) + 2 * (1 + 10) + 20;

  struct Parameters {
    // Time in blocks during which a submitted result can be challenged.
    uint256 resultChallengePeriodLength;
    // Time in blocks after which the next group member is eligible
    // to submit DKG result.
    uint256 resultSubmissionEligibilityDelay;
  }

  struct Data {
    // DKG parameters. The parameters should persist between DKG executions.
    // They should be updated with dedicated set functions only when DKG is not
    // in progress.
    Parameters parameters;
    // Time in blocks at which DKG started.
    uint256 startBlock;
    // Hash of submitted DKG result.
    bytes32 submittedResultHash;
    // Block number from the moment of the DKG result submission.
    uint256 submittedResultBlock;
  }

  /// @notice States for phases of group creation.
  /// The states doesn't include timeouts which should be tracked and notified
  /// individually.
  enum State {
    // Group creation is not in progress. It is a state set after group creation
    // completion either by timeout or by a result approval.
    IDLE,
    // Off-chain DKG protocol execution is in progress. A result is being calculated
    // by the clients in this state. It's not yet possible to submit the result.
    KEY_GENERATION,
    // After off-chain DKG protocol execution the contract awaits result submission.
    // This is a state to which group creation returns in case of a result
    // challenge notification.
    AWAITING_RESULT,
    // DKG result was submitted and awaits an approval or a challenge. If a result
    // gets challenge the state returns to `AWAITING_RESULT`. If a result gets
    // approval the state changes to `IDLE`.
    CHALLENGE
  }

  /// @notice DKG result.
  struct Result {
    // Claimed submitter candidate group member index
    uint256 submitterMemberIndex;
    // Generated candidate group public key
    bytes groupPubKey;
    // Bytes array of misbehaved (disqualified or inactive)
    bytes misbehaved;
    // Concatenation of signatures from members supporting the result.
    // The message to be signed by each member is keccak256 hash of the
    // calculated group public key, misbehaved members as bytes and DKG
    // start block. The calculated hash should be prefixed with prefixed with
    // `\x19Ethereum signed message:\n` before signing, so the message to
    // sign is:
    // `\x19Ethereum signed message:\n${keccak256(groupPubKey,misbehaved,startBlock)}`
    bytes signatures;
    // Indices of members corresponding to each signature. Indices have to be unique.
    uint256[] signingMemberIndices;
    // Addresses of candidate group members as outputted by the group selection protocol.
    address[] members;
  }

  /// @notice Determines the current state of group creation. It doesn't take
  ///         timeouts into consideration. The timeouts should be tracked and
  ///         notified separately.
  function currentState(Data storage self)
    internal
    view
    returns (State state)
  {
    state = State.IDLE;

    if (self.startBlock > 0) {
      state = State.KEY_GENERATION;

      if (block.number > self.startBlock + offchainDkgTime) {
        state = State.AWAITING_RESULT;

        if (self.submittedResultBlock > 0) {
          state = State.CHALLENGE;
        }
      }
    }
  }

  function start(Data storage self) internal {
    require(currentState(self) == State.IDLE, "current state is not IDLE");

    self.startBlock = block.number;
  }

  function submitResult(Data storage self, Result calldata result) internal {
    require(
      currentState(self) == State.AWAITING_RESULT,
      "current state is not AWAITING_RESULT"
    );
    require(!hasDkgTimedOut(self), "dkg timeout already passed");

    verify(
      self,
      result.submitterMemberIndex,
      result.groupPubKey,
      result.misbehaved,
      result.signatures,
      result.signingMemberIndices,
      result.members
    );

    self.submittedResultHash = keccak256(abi.encode(result));
    self.submittedResultBlock = block.number;
  }

  /// @notice Checks if DKG timed out. The DKG timeout period includes time required
  ///         for off-chain protocol execution and time for the result publication
  ///         for all group members. After this time result cannot be submitted
  ///         and DKG can be notified about the timeout.
  /// @return True if DKG timed out, false otherwise.
  function hasDkgTimedOut(Data storage self) internal view returns (bool) {
    return
      currentState(self) == State.AWAITING_RESULT &&
      block.number >
      (self.startBlock +
        offchainDkgTime +
        groupSize *
        self.parameters.resultSubmissionEligibilityDelay);
  }

  /// @notice Verifies the submitted DKG result against supporting member
  ///         signatures and if the submitter is eligible to submit at the current
  ///         block. Every signature supporting the result has to be from a unique
  ///         group member.
  /// @dev The message to be signed by each member is keccak256 hash of the
  ///      calculated group public key, misbehaved members as bytes and DKG
  ///      start block. The calculated hash should be prefixed with prefixed with
  ///      `\x19Ethereum signed message:\n` before signing, so the message to
  ///      sign is:
  ///      `\x19Ethereum signed message:\n${keccak256(groupPubKey,misbehaved,startBlock)}`
  /// @param submitterMemberIndex Claimed submitter candidate group member index
  /// @param groupPubKey Generated candidate group public key
  /// @param misbehaved Bytes array of misbehaved (disqualified or inactive)
  ///        group members indexes; Indexes reflect positions of members in the group,
  ///        as outputted by the group selection protocol.
  /// @param signatures Concatenation of signatures from members supporting the
  ///        result.
  /// @param signingMemberIndices Indices of members corresponding to each
  ///        signature. Indices have to be unique.
  /// @param members Addresses of candidate group members as outputted by the
  ///        group selection protocol.
  function verify(
    Data storage self,
    uint256 submitterMemberIndex,
    bytes memory groupPubKey,
    bytes memory misbehaved,
    bytes memory signatures,
    uint256[] memory signingMemberIndices,
    address[] memory members
  ) internal view {
    // TODO: Verify if submitter is valid staker and signatures come from valid
    // stakers https://github.com/keep-network/keep-core/pull/2654#discussion_r728226906.

    require(submitterMemberIndex > 0, "Invalid submitter index");
    require(
      members[submitterMemberIndex - 1] == msg.sender,
      "Unexpected submitter index"
    );

    // TODO: In challenges implementation remember about resetting the counter for
    // eligibility checks, see: https://github.com/keep-network/keep-core/pull/2654#discussion_r728819993
    uint256 T_init = self.startBlock + offchainDkgTime;
    require(
      block.number >=
        (T_init +
          (submitterMemberIndex - 1) *
          self.parameters.resultSubmissionEligibilityDelay),
      "Submitter not eligible"
    );

    require(groupPubKey.length == 128, "Malformed group public key");

    require(
      misbehaved.length <= groupSize - signatureThreshold,
      "Malformed misbehaved bytes"
    );

    uint256 signaturesCount = signatures.length / 65;
    require(signatures.length >= 65, "Too short signatures array");
    require(signatures.length % 65 == 0, "Malformed signatures array");
    require(
      signaturesCount == signingMemberIndices.length,
      "Unexpected signatures count"
    );
    require(signaturesCount >= signatureThreshold, "Too few signatures");
    require(signaturesCount <= groupSize, "Too many signatures");

    bytes32 resultHash = keccak256(
      abi.encodePacked(groupPubKey, misbehaved, self.startBlock)
    );

    bytes memory current; // Current signature to be checked.

    bool[] memory usedMemberIndices = new bool[](groupSize);

    for (uint256 i = 0; i < signaturesCount; i++) {
      uint256 memberIndex = signingMemberIndices[i];
      require(memberIndex > 0, "Invalid index");
      require(memberIndex <= members.length, "Index out of range");

      require(!usedMemberIndices[memberIndex - 1], "Duplicate member index");
      usedMemberIndices[memberIndex - 1] = true;

      current = signatures.slice(65 * i, 65);
      address recoveredAddress = resultHash.toEthSignedMessageHash().recover(
        current
      );
      require(
        members[memberIndex - 1] == recoveredAddress,
        "Invalid signature"
      );
    }
  }

  /// @notice Set resultChallengePeriodLength parameter.
  function setResultChallengePeriodLength(
    Data storage self,
    uint256 newResultChallengePeriodLength
  ) internal {
    require(currentState(self) == State.IDLE, "current state is not IDLE");

    require(
      newResultChallengePeriodLength > 0,
      "new value should be greater than zero"
    );

    self
      .parameters
      .resultChallengePeriodLength = newResultChallengePeriodLength;
  }

  /// @notice Set resultSubmissionEligibilityDelay parameter.
  function setResultSubmissionEligibilityDelay(
    Data storage self,
    uint256 newResultSubmissionEligibilityDelay
  ) internal {
    require(currentState(self) == State.IDLE, "current state is not IDLE");

    require(
      newResultSubmissionEligibilityDelay > 0,
      "new value should be greater than zero"
    );

    self
      .parameters
      .resultSubmissionEligibilityDelay = newResultSubmissionEligibilityDelay;
  }
}
