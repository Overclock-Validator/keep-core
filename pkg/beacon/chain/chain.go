package chain

import (
	"bytes"
	"fmt"
	"github.com/keep-network/keep-core/pkg/chain"
	"github.com/keep-network/keep-core/pkg/sortition"
	"math/big"

	"github.com/keep-network/keep-core/pkg/beacon/event"
	"github.com/keep-network/keep-core/pkg/gen/async"
	"github.com/keep-network/keep-core/pkg/subscription"
)

// GroupMemberIndex is an index of a random beacon group member.
// Maximum value accepted by the chain is 255.
type GroupMemberIndex = uint8

// RelayEntryInterface defines the subset of the beacon chain interface that
// pertains specifically to submission and retrieval of relay requests and
// entries.
type RelayEntryInterface interface {
	// SubmitRelayEntry submits an entry in the random beacon and returns a
	// promise to track the submission progress. The promise is fulfilled when
	// the entry has been successfully submitted to the on-chain, or failed if
	// the entry submission failed.
	SubmitRelayEntry(entry []byte) *async.EventRelayEntrySubmittedPromise
	// OnRelayEntrySubmitted is a callback that is invoked when an on-chain
	// notification of a new, valid relay entry is seen.
	OnRelayEntrySubmitted(
		func(entry *event.RelayEntrySubmitted),
	) subscription.EventSubscription
	// OnRelayEntryRequested is a callback that is invoked when an on-chain
	// notification of a new, valid relay request is seen.
	OnRelayEntryRequested(
		func(request *event.Request),
	) subscription.EventSubscription
	// ReportRelayEntryTimeout notifies the chain when a selected group which was
	// supposed to submit a relay entry, did not deliver it within a specified
	// time frame (relayEntryTimeout) counted in blocks.
	ReportRelayEntryTimeout() error
	// IsEntryInProgress checks if a new relay entry is currently in progress.
	IsEntryInProgress() (bool, error)
	// CurrentRequestStartBlock returns a start block of a current entry.
	CurrentRequestStartBlock() (*big.Int, error)
	// CurrentRequestPreviousEntry returns previous entry of a current request.
	CurrentRequestPreviousEntry() ([]byte, error)
	// CurrentRequestGroupPublicKey returns group public key for the current request.
	CurrentRequestGroupPublicKey() ([]byte, error)
}

// GroupSelectionInterface defines the subset of the beacon chain interface that
// pertains to the group selection activities.
type GroupSelectionInterface interface {
	// SelectGroup returns the group members for the group generated by
	// the given seed. This function can return an error if the beacon chain's
	// state does not allow for group selection at the moment.
	SelectGroup(seed *big.Int) ([]chain.Address, error)
}

// GroupRegistrationInterface defines the subset of the beacon chain interface
// that pertains to the group registration activities.
type GroupRegistrationInterface interface {
	// OnGroupRegistered is a callback that is invoked when an on-chain
	// notification of a new, valid group being registered is seen.
	OnGroupRegistered(
		func(groupRegistration *event.GroupRegistration),
	) subscription.EventSubscription
	// IsGroupRegistered checks if group with the given public key is registered
	// on-chain.
	IsGroupRegistered(groupPublicKey []byte) (bool, error)
	// IsStaleGroup checks if a group with the given public key is considered
	// as stale on-chain. Group is considered as stale if it is expired and when
	// its expiration time and potentially executed operation timeout are both
	// in the past. Stale group is never selected by the chain to any new
	// operation.
	IsStaleGroup(groupPublicKey []byte) (bool, error)
	// GetGroupMembers returns `GroupSize` slice of addresses of
	// participants which have been selected to the group with given public key.
	GetGroupMembers(groupPublicKey []byte) ([]chain.Address, error)
}

// GroupInterface defines the subset of the beacon chain interface that pertains
// specifically to the group management.
type GroupInterface interface {
	GroupSelectionInterface
	GroupRegistrationInterface
}

// DistributedKeyGenerationInterface defines the subset of the beacon chain
// interface that pertains specifically to group formation's distributed key
// generation process.
type DistributedKeyGenerationInterface interface {
	// OnDKGStarted registers a callback that is invoked when an on-chain
	// notification of the DKG process start is seen.
	OnDKGStarted(
		func(event *event.DKGStarted),
	) subscription.EventSubscription
	// SubmitDKGResult sends DKG result to a chain, along with signatures over
	// result hash from group participants supporting the result.
	// Signatures over DKG result hash are collected in a map keyed by signer's
	// member index.
	SubmitDKGResult(
		participantIndex GroupMemberIndex,
		dkgResult *DKGResult,
		signatures map[GroupMemberIndex][]byte,
	) error
	// OnDKGResultSubmitted registers a callback that is invoked when an on-chain
	// notification of a new, valid submitted result is seen.
	OnDKGResultSubmitted(
		func(event *event.DKGResultSubmission),
	) subscription.EventSubscription
	// CalculateDKGResultHash calculates 256-bit hash of DKG result in standard
	// specific for the chain. Operation is performed off-chain.
	CalculateDKGResultHash(dkgResult *DKGResult) (DKGResultHash, error)
}

// Interface represents the interface that the random beacon expects to interact
// with the anchoring blockchain on.
type Interface interface {
	// GetConfig returns the expected configuration of the random beacon.
	GetConfig() *Config
	// BlockCounter returns the chain's block counter.
	BlockCounter() (chain.BlockCounter, error)
	// Signing returns the chain's signer.
	Signing() chain.Signing
	// StakeMonitor returns the chain's stake monitor.
	StakeMonitor() (chain.StakeMonitor, error)

	sortition.Chain
	GroupInterface
	RelayEntryInterface
	DistributedKeyGenerationInterface
}

// Config contains the config data needed for the random beacon to operate.
// TODO: Adjust to the random beacon v2 requirements.
type Config struct {
	// GroupSize is the size of a group in the random beacon.
	GroupSize int
	// HonestThreshold is the minimum number of active participants behaving
	// according to the protocol needed to generate a new relay entry.
	HonestThreshold int
	// ResultPublicationBlockStep is the duration (in blocks) that has to pass
	// before group member with the given index is eligible to submit the
	// result.
	// Nth player becomes eligible to submit the result after
	// T_dkg + (N-1) * T_step
	// where T_dkg is time for phases 1-12 to complete and T_step is the result
	// publication block step.
	ResultPublicationBlockStep uint64
	// RelayEntryTimeout is a timeout in blocks on-chain for a relay
	// entry to be published by the selected group. Blocks are
	// counted from the moment relay request occur.
	RelayEntryTimeout uint64
}

// DishonestThreshold is the maximum number of misbehaving participants for
// which it is still possible to generate a new relay entry.
// Misbehaviour is any misconduct to the protocol, including inactivity.
func (c *Config) DishonestThreshold() int {
	return c.GroupSize - c.HonestThreshold
}

// DKGResult is a result of distributed key generation protocol.
//
// If the protocol execution finishes with an acceptable number of disqualified
// or inactive members, the group with remaining list of honest members will
// be added to the signing groups list for the random beacon.
//
// Otherwise, group creation will not finish, which will be due to either the
// number of inactive or disqualified participants, or the results (signatures)
// being disputed in a way where the correct outcome cannot be ascertained.
type DKGResult struct {
	// Group public key generated by the protocol execution, empty if the protocol failed.
	GroupPublicKey []byte
	// Misbehaved members are all members either inactive or disqualified.
	// Misbehaved members are represented as a slice of bytes for optimizing
	// on-chain storage. Each byte is an inactive or disqualified member index.
	Misbehaved []byte
}

// DKGResultHash is a 256-bit hash of DKG Result. The hashing algorithm should
// be the same as the one used on-chain.
type DKGResultHash [hashByteSize]byte

const hashByteSize = 32

// DKGResultsVotes is a map of votes for each DKG Result.
type DKGResultsVotes map[DKGResultHash]int

// Equals checks if two DKG results are equal.
func (r *DKGResult) Equals(r2 *DKGResult) bool {
	if r == nil || r2 == nil {
		return r == r2
	}
	if !bytes.Equal(r.GroupPublicKey, r2.GroupPublicKey) {
		return false
	}
	if !bytes.Equal(r.Misbehaved, r2.Misbehaved) {
		return false
	}

	return true
}

// DKGResultHashFromBytes converts bytes slice to DKG Result Hash. It requires
// provided bytes slice size to be exactly 32 bytes.
func DKGResultHashFromBytes(bytes []byte) (DKGResultHash, error) {
	var hash DKGResultHash

	if len(bytes) != hashByteSize {
		return hash, fmt.Errorf("bytes length is not equal %v", hashByteSize)
	}
	copy(hash[:], bytes[:])

	return hash, nil
}
