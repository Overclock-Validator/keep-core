pragma solidity ^0.5.17;

import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/math/Math.sol";

/// @title Rewards
/// @dev A contract for distributing KEEP token rewards to keeps.
/// When a reward contract is created,
/// the creator defines a reward schedule
/// consisting of one or more reward intervals and their interval weights,
/// the length of reward intervals,
/// and the quota of how many keeps must be created in an interval
/// for the full reward for that interval to be paid out.
///
/// The amount of KEEP to be distributed is determined by funding the contract,
/// and additional KEEP can be added at any time.
/// The reward contract is funded with `approveAndCall` with no extra data,
/// but it also collects any KEEP mistakenly sent to it in any other way.
///
/// An interval is defined by the timestamps [startOf, endOf);
/// a keep created at the time `startOf(i)` belongs to interval `i`
/// and one created at `endOf(i)` belongs to `i+1`.
///
/// When an interval is over,
/// it will be allocated a percentage of the remaining unallocated rewards
/// based on its weight,
/// and adjusted by the number of keeps created in the interval
/// if the quota is not met.
/// The adjustment for not meeting the keep quota is a percentage
/// that equals the percentage of the quota that was met;
/// if the number of keeps created is 80% of the quota
/// then 80% of the base reward will be allocated for the interval.
///
/// Any unallocated rewards will stay in the unallocated rewards pool,
/// to be allocated for future intervals.
/// Intervals past the initially defined schedule have a weight of 100%,
/// meaning that all remaining unallocated rewards
/// will be allocated to the interval.
///
/// Keeps of the appropriate type can receive rewards
/// once the interval they were created in is over,
/// and the keep has closed happily.
/// There is no time limit to receiving rewards,
/// nor is there need to wait for all keeps from the interval to close.
/// Calling `receiveReward` automatically allocates the rewards
/// for the interval the specified keep was created in
/// and all previous intervals.
///
/// If a keep is terminated,
/// that fact can be reported to the reward contract.
/// Reporting a terminated keep returns its allocated reward
/// to the pool of unallocated rewards.
///
/// A concrete implementation of the abstract rewards contract
/// must specify functions for accessing information about keeps
/// and paying out rewards.
/// For the purpose of rewards,
/// Random Beacon signing groups count as "keeps"
/// and the beacon operator contract acts as the "factory".
contract Rewards {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public token;

    // Total number of keep tokens to distribute.
    uint256 totalRewards;
    // Rewards that haven't been allocated to finished intervals
    uint256 unallocatedRewards;
    // Rewards that have been paid out;
    // `token.balanceOf(address(this))` should always equal
    // `totalRewards.sub(paidOutRewards)`
    uint256 paidOutRewards;

    // Length of one interval in seconds (timestamp diff).
    uint256 termLength;
    // Timestamp of first interval beginning.
    uint256 firstIntervalStart;

    // Minimum number of keep submissions for each interval.
    uint256 minimumKeepsPerInterval;

    // Array representing the percentage of unallocated rewards
    // available for each reward interval.
    uint256[] intervalWeights; // percent array
    // Mapping of interval number to tokens allocated for the interval.
    uint256[] intervalAllocations;

    // mapping of keeps to booleans.
    // True if the keep has been used to claim a reward.
    mapping(bytes32 => bool) claimed;

    // Mapping of interval to number of keeps created in/before the interval
    mapping(uint256 => uint256) keepsByInterval;

    // Mapping of interval to number of keeps whose rewards have been paid out,
    // or reallocated because the keep closed unhappily
    mapping(uint256 => uint256) intervalKeepsProcessed;

    constructor (
        uint256 _termLength,
        address _token,
        uint256 _minimumKeepsPerInterval,
        uint256 _firstIntervalStart,
        uint256[] memory _intervalWeights
    ) public {
        token = IERC20(_token);
        termLength = _termLength;
        firstIntervalStart = _firstIntervalStart;
        minimumKeepsPerInterval = _minimumKeepsPerInterval;
        intervalWeights = _intervalWeights;
    }

    /// @notice Funds the rewards contract.
    /// @dev Adds the received amount of tokens
    /// to `totalRewards` and `unallocatedRewards`.
    /// May be called at any time, even after allocating some intervals.
    /// Changes to `unallocatedRewards`
    /// will take effect on subsequent interval allocations.
    /// Intended to be used with `approveAndCall`.
    /// If the reward contract has received tokens outside `approveAndCall`,
    /// this collects them as well.
    /// @param _from The original sender of the tokens.
    /// Must have approved at least `_value` tokens for the rewards contract.
    /// @param _value The amount of tokens to fund.
    /// @param _token The token to fund the rewards in.
    /// Must match the one specified in the rewards contract.
    function receiveApproval(
        address _from,
        uint256 _value,
        address _token,
        bytes memory
    ) public {
        require(IERC20(_token) == token, "Unsupported token");

        token.safeTransferFrom(_from, address(this), _value);

        uint256 currentBalance = token.balanceOf(address(this));
        uint256 beforeBalance = _unpaidRewards();
        require(
            currentBalance >= beforeBalance,
            "Reward contract has lost tokens"
        );

        uint256 addedBalance = currentBalance.sub(beforeBalance);

        totalRewards = totalRewards.add(addedBalance);
        unallocatedRewards = unallocatedRewards.add(addedBalance);
    }

    /// @notice Sends the reward for a keep to the keep members.
    /// @param keepIdentifier A unique identifier for the keep,
    /// e.g. address or number converted to a `bytes32`.
    function receiveReward(bytes32 keepIdentifier)
        factoryMustRecognize(keepIdentifier)
        rewardsNotClaimed(keepIdentifier)
        mustBeClosed(keepIdentifier)
        public
    {
        _processKeep(true, keepIdentifier);
    }

    /// @notice Report that the keep was terminated,
    /// and return its allocated rewards to the unallocated pool.
    /// @param keepIdentifier The terminated keep.
    function reportTermination(bytes32 keepIdentifier)
        factoryMustRecognize(keepIdentifier)
        rewardsNotClaimed(keepIdentifier)
        mustBeTerminated(keepIdentifier)
        public
    {
        _processKeep(false, keepIdentifier);
    }

    /// @notice Checks if a keep is eligible to receive rewards.
    /// @dev Keeps that close dishonorably or early are not eligible for rewards.
    /// @param _keep The keep to check.
    /// @return True if the keep is eligible, false otherwise
    function eligibleForReward(bytes32 _keep) public view returns (bool){
        bool _claimed = _rewardClaimed(_keep);
        bool closed = _isClosed(_keep);
        bool recognized = _recognizedByFactory(_keep);
        return !_claimed && closed && recognized;
    }

    /// @notice Checks if a keep is terminated
    /// and thus its rewards can be returned to the unallocated pool.
    /// @param _keep The keep to check.
    /// @return True if the keep is terminated, false otherwise
    function eligibleButTerminated(bytes32 _keep) public view returns (bool) {
        bool _claimed = _rewardClaimed(_keep);
        bool terminated = _isTerminated(_keep);
        bool recognized = _recognizedByFactory(_keep);
        return !_claimed && terminated && recognized;
    }

    /// @notice Return the interval number
    /// the provided timestamp falls within.
    /// @dev If the timestamp is before `firstIntervalStart`,
    /// the interval is 0.
    /// @param timestamp The timestamp whose interval is queried.
    /// @return The interval of the timestamp.
    function intervalOf(uint256 timestamp) public view returns (uint256) {
        uint256 _firstIntervalStart = firstIntervalStart;
        uint256 _termLength = termLength;

        if (timestamp < _firstIntervalStart) {
            return 0;
        }

        uint256 difference = timestamp.sub(_firstIntervalStart);
        uint256 interval = difference.div(_termLength);

        return interval;
    }

    /// @notice Return the timestamp corresponding to the start of the interval.
    /// @dev The start of an interval is inclusive;
    /// a keep created at the timestamp `startOf(i)` is in interval `i`.
    /// @param interval The interval whose start is queried.
    function startOf(uint256 interval) public view returns (uint256) {
        return firstIntervalStart.add(interval.mul(termLength));
    }

    /// @notice Return the timestamp corresponding to the end of the interval.
    /// @dev The end of an interval is exclusive;
    /// a keep created at the timestamp `endOf(i)` is in interval `i+1`.
    /// @param interval The interval whose end is queried.
    function endOf(uint256 interval) public view returns (uint256) {
        return startOf(interval.add(1));
    }

    /// @notice Return the number of keeps created before `intervalEndpoint`
    /// @dev Wraps the binary search of `_find`
    /// with a number of checks for edge cases.
    function _findEndpoint(uint256 intervalEndpoint) public view returns (uint256) {
        require(
            intervalEndpoint <= block.timestamp,
            "interval hasn't ended yet"
        );
        uint256 keepCount = _getKeepCount();
        // no keeps created yet -> return 0
        if (keepCount == 0) {
            return 0;
        }

        uint256 lb = 0; // lower bound, inclusive
        uint256 timestampLB = _getCreationTime(_getKeepAtIndex(lb));
        // all keeps created after the interval -> return 0
        if (timestampLB >= intervalEndpoint) {
            return 0;
        }

        uint256 ub = keepCount.sub(1); // upper bound, inclusive
        uint256 timestampUB = _getCreationTime(_getKeepAtIndex(ub));
        // all keeps created in or before the interval -> return keep count
        if (timestampUB < intervalEndpoint) {
            return keepCount;
        }

        // The above cases also cover the case
        // where only 1 keep has been created;
        // lb == ub
        // if it was created after the interval, return 0
        // otherwise, return 1

        return _find(lb, timestampLB, ub, timestampUB, intervalEndpoint);
    }

    /// @notice Return the number of keeps created before `targetTime`,
    /// with specified upper and lower bounds.
    /// @dev Binary search assumes the following invariants:
    ///   lb >= 0, lbTime < targetTime
    ///   ub < keepCount, ubTime >= targetTime
    /// @param _lb The lower bound of the search (inclusive)
    /// @param _lbTime The creation time of keep number `lb`
    /// @param _ub The upper bound of the search (inclusive)
    /// @param _ubTime The creation time of keep number `ub`
    /// @param targetTime The target time
    function _find(
        uint256 _lb,
        uint256 _lbTime,
        uint256 _ub,
        uint256 _ubTime,
        uint256 targetTime
    ) internal view returns (uint256) {
        uint256 lb = _lb;
        uint256 lbTime = _lbTime;
        uint256 ub = _ub;
        uint256 ubTime = _ubTime;
        uint256 len = ub.sub(lb);
        while (len > 1) {
            // ub >= lb + 2
            // mid > lb
            uint256 mid = lb.add(len.div(2));
            uint256 midTime = _getCreationTime(_getKeepAtIndex(mid));

            if (midTime >= targetTime) {
                ub = mid;
                ubTime = midTime;
            } else {
                lb = mid;
                lbTime = midTime;
            }
            len = ub.sub(lb);
        }
        return ub;
    }

    /// @notice Return the endpoint index of the interval,
    /// i.e. the number of keeps created in and before the interval.
    /// The interval must have ended;
    /// otherwise the endpoint might still change.
    /// @dev Uses a locally cached result,
    /// and stores the result if it isn't cached yet.
    /// All keeps created before the initiation fall in interval 0.
    /// @param interval The number of the interval.
    /// @return endpoint The number of keeps the factory had created
    /// before the end of the interval.
    function _getEndpoint(uint256 interval)
        mustBeFinished(interval)
        internal
        returns (uint256 endpoint)
    {
        // Get the endpoint from local cache;
        // might not be recorded yet
        uint256 maybeEndpoint = keepsByInterval[interval];

        // Either the endpoint is zero
        // (no keeps created by the end of the interval)
        // or the endpoint isn't cached yet
        if (maybeEndpoint == 0) {
            // Check what the real endpoint is
            // if the actual value is 0, this call short-circuits
            // so we don't need to special-case the zero
            uint256 realEndpoint = _findEndpoint(endOf(interval));
            // We didn't have the correct value cached,
            // so store it
            if (realEndpoint != 0) {
                keepsByInterval[interval] = realEndpoint;
            }
            endpoint = realEndpoint;
        } else {
            endpoint = maybeEndpoint;
        }
        return endpoint;
    }

    function _getPreviousEndpoint(uint256 interval) internal returns (uint256) {
        if (interval == 0) {
            return 0;
        } else {
            return _getEndpoint(interval.sub(1));
        }
    }

    function _keepsInInterval(uint256 interval) internal returns (uint256) {
        return (_getEndpoint(interval).sub(_getPreviousEndpoint(interval)));
    }

    /// @notice Calculate the reward allocation adjustment percentage
    /// when an interval has an insufficient number of keeps.
    /// @dev An interval with at least `minimumKeepsPerInterval` keeps
    /// will have the full reward allocated to it.
    /// An interval with fewer keeps will only be allocated
    /// a fraction of the base reward
    /// equaling the fraction of the quota that was met.

    /// @notice Return the percentage of remaining unallocated rewards
    /// that is to be allocated to the specified `interval`
    function _getIntervalWeight(uint256 interval) internal view returns (uint256) {
        if (interval < _getIntervalCount()) {
            return intervalWeights[interval];
        } else {
            return 100;
        }
    }

    function _getIntervalCount() internal view returns (uint256) {
        return intervalWeights.length;
    }

    function _baseAllocation(uint256 interval) internal view returns (uint256) {
        uint256 _unallocatedRewards = unallocatedRewards;
        uint256 weightPercentage = _getIntervalWeight(interval);
        return _unallocatedRewards.mul(weightPercentage).div(100);
    }

    function _adjustedAllocation(uint256 interval) internal returns (uint256) {
        uint256 __baseAllocation = _baseAllocation(interval);
        if (__baseAllocation == 0) {
            return 0;
        }
        uint256 keepCount = _keepsInInterval(interval);
        uint256 minimumKeeps = minimumKeepsPerInterval;
        uint256 adjustmentCount = Math.max(keepCount, minimumKeeps);
        return __baseAllocation.div(adjustmentCount).mul(keepCount);
    }

    function _rewardPerKeep(uint256 interval) internal returns (uint256) {
        uint256 __adjustedAllocation = _adjustedAllocation(interval);
        if (__adjustedAllocation == 0) {
            return 0;
        }
        uint256 keepCount = _keepsInInterval(interval);
        // Adjusted allocation would be zero if keep count was zero
        assert(keepCount > 0);
        return __adjustedAllocation.div(keepCount);
    }

    function _allocateRewards(uint256 interval)
        mustBeFinished(interval)
        internal
    {
        uint256 allocatedIntervals = intervalAllocations.length;
        require(
            !(interval < allocatedIntervals),
            "Interval already allocated"
        );
        // Allocate previous intervals first
        if (interval > allocatedIntervals) {
            _allocateRewards(interval.sub(1));
        }
        uint256 totalAllocation = _adjustedAllocation(interval);
        // Calculate like this so rewards divide equally among keeps
        unallocatedRewards = unallocatedRewards.sub(totalAllocation);
        intervalAllocations.push(totalAllocation);
    }

    /// @notice Get the total amount of tokens
    /// allocated for all keeps in the specified interval.
    function _getAllocatedRewards(uint256 interval) internal view returns (uint256) {
        require(
            interval < intervalAllocations.length,
            "Interval not allocated yet"
        );
        return intervalAllocations[interval];
    }

    /// @notice Return whether the specified interval has been allocated.
    function _isAllocated(uint256 interval) internal view returns (bool) {
        uint256 allocatedIntervals = intervalAllocations.length;
        return (interval < allocatedIntervals);
    }

    function _processKeep(
        bool eligible,
        bytes32 keepIdentifier
    ) internal {
        uint256 creationTime = _getCreationTime(keepIdentifier);
        uint256 interval = intervalOf(creationTime);
        if (!_isAllocated(interval)) {
            _allocateRewards(interval);
        }
        uint256 allocation = intervalAllocations[interval];
        uint256 __keepsInInterval = _keepsInInterval(interval);
        uint256 perKeepReward = allocation.div(__keepsInInterval);
        uint256 processedKeeps = intervalKeepsProcessed[interval];
        claimed[keepIdentifier] = true;
        intervalKeepsProcessed[interval] = processedKeeps.add(1);

        if (eligible) {
            paidOutRewards = paidOutRewards.add(perKeepReward);
            _distributeReward(keepIdentifier, perKeepReward);
        } else {
            // Return the reward to the unallocated pool
            unallocatedRewards = unallocatedRewards.add(perKeepReward);
        }
    }

    function _unpaidRewards() internal view returns (uint256) {
        return totalRewards.sub(paidOutRewards);
    }

    function _rewardClaimed(bytes32 _keep) internal view returns (bool) {
        return claimed[_keep];
    }

    function _isFinished(uint256 interval) internal view returns (bool) {
        return block.timestamp >= endOf(interval);
    }

    function _getKeepCount() internal view returns (uint256);
    function _getKeepAtIndex(uint256 index) internal view returns (bytes32);
    function _getCreationTime(bytes32 _keep) internal view returns (uint256);
    function _isClosed(bytes32 _keep) internal view returns (bool);
    function _isTerminated(bytes32 _keep) internal view returns (bool);
    function _recognizedByFactory(bytes32 _keep) internal view returns (bool);
    function _distributeReward(bytes32 _keep, uint256 amount) internal;

    modifier rewardsNotClaimed(bytes32 _keep) {
        require(
            !_rewardClaimed(_keep),
            "Rewards already claimed");
        _;
    }

    modifier mustBeFinished(uint256 interval) {
        require(
            _isFinished(interval),
            "Interval hasn't ended yet");
        _;
    }

    modifier mustBeClosed(bytes32 _keep) {
        require(
            _isClosed(_keep),
            "Keep is not closed");
        _;
    }

    modifier mustBeTerminated(bytes32 _keep) {
        require(
            _isTerminated(_keep),
            "Keep is not terminated");
        _;
    }

    modifier factoryMustRecognize(bytes32 _keep) {
        require(
            _recognizedByFactory(_keep),
            "Keep address not recognized by factory");
        _;
    }
}
