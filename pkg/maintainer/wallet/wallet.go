package wallet

import (
	"context"

	"time"

	"github.com/ipfs/go-log/v2"

	"github.com/keep-network/keep-core/pkg/bitcoin"
)

const (
	redemptionInterval = 3 * time.Hour
	sweepInterval      = 48 * time.Hour
)

var logger = log.Logger("keep-maintainer-wallet")

type walletMaintainer struct {
	chain    Chain
	btcChain bitcoin.Chain
}

// Initialize and start Wallet Coordination Maintainer.
func Initialize(
	parentCtx context.Context,
	chain Chain,
	btcChain bitcoin.Chain,
) {
	wm := &walletMaintainer{
		chain:    chain,
		btcChain: btcChain,
	}

	go wm.startControlLoop(parentCtx)
}

// startControlLoop starts the loop responsible for controlling the wallet
// coordination maintainer.
func (wm *walletMaintainer) startControlLoop(ctx context.Context) {
	logger.Info("starting wallet coordination maintainer")
	defer logger.Info("stopping wallet coordination maintainer")

	// TODO: Cache time of the last execution in the disk storage, so after a
	// restart the client will wait instead of executing the task right away.
	initialRedemptionDelay := 10 * time.Second
	initialSweepDelay := 10 * time.Second

	redemptionTicker := time.NewTicker(initialRedemptionDelay)
	defer redemptionTicker.Stop()

	sweepTicker := time.NewTicker(initialSweepDelay)
	defer sweepTicker.Stop()

	logger.Infof("waiting [%s] until redemption task execution", initialRedemptionDelay)
	logger.Infof("waiting [%s] until sweep task execution", initialSweepDelay)

	for {
		select {
		case <-ctx.Done():
			logger.Infof("tBTC Deposits Sweep Maintainer closed")
			return
		case <-redemptionTicker.C:
			// TODO: Implement
			sweepTicker.Reset(redemptionInterval)
		case <-sweepTicker.C:
			// TODO: Synchronize sweeps with redemptions. Sweep should be proposed only
			// if there are no pending redemptions. Redemptions take priority over sweeps.
			if err := wm.runSweepTask(ctx); err != nil {
				logger.Errorf("failed to run sweep task: [%w]")
			}

			logger.Infof("sweep task run completed; next run in [%s]", sweepInterval)

			sweepTicker.Reset(sweepInterval)
		}
	}
}
