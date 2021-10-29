/* eslint-disable @typescript-eslint/no-unused-expressions */

import { ethers, waffle, helpers } from "hardhat"
import { expect } from "chai"
import { Contract, ContractTransaction } from "ethers"
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers"
import { randomBeaconDeployment } from "./fixtures"
import type { RandomBeacon, SortitionPoolStub } from "../typechain"

const { time } = helpers
const { increaseTime } = time

describe("RandomBeacon - Pool", () => {
  let operator: SignerWithAddress
  let randomBeacon: Contract
  let sortitionPoolStub: Contract

  // prettier-ignore
  before(async () => {
    [operator] = await ethers.getSigners()
  })

  beforeEach("load test fixture", async () => {
    const contracts = await waffle.loadFixture(randomBeaconDeployment)

    sortitionPoolStub = contracts.sortitionPoolStub as SortitionPoolStub
    randomBeacon = contracts.randomBeacon as RandomBeacon
  })

  describe("registerOperator", () => {
    context("when the operator is not registered yet", () => {
      context("when there is no active punishment for given operator", () => {
        beforeEach(async () => {
          await randomBeacon.connect(operator).registerOperator()
        })

        it("should deposit gas", async () => {
          expect(await randomBeacon.hasGasDeposit(operator.address)).to.be.true
        })

        it("should register the operator", async () => {
          expect(await sortitionPoolStub.operators(operator.address)).to.be.true
        })
      })

      context("when punishment for given operator already elapsed", () => {
        beforeEach(async () => {
          const punishmentDuration = 1209600 // 2 weeks
          await randomBeacon.publicPunishOperators(
            [operator.address],
            punishmentDuration
          )

          await increaseTime(punishmentDuration)

          await randomBeacon.connect(operator).registerOperator()
        })

        it("should deposit gas", async () => {
          expect(await randomBeacon.hasGasDeposit(operator.address)).to.be.true
        })

        it("should register the operator", async () => {
          expect(await sortitionPoolStub.operators(operator.address)).to.be.true
        })

        it("should remove operator from punished operators map", async () => {
          expect(
            await randomBeacon.punishedOperators(operator.address)
          ).to.be.equal(0)
        })
      })

      context("when there is an active punishment for given operator", () => {
        beforeEach(async () => {
          const punishmentDuration = 1209600 // 2 weeks
          await randomBeacon.publicPunishOperators(
            [operator.address],
            punishmentDuration
          )

          await increaseTime(punishmentDuration - 1)
        })

        it("should revert", async () => {
          await expect(
            randomBeacon.connect(operator).registerOperator()
          ).to.be.revertedWith("Operator has an active punishment")
        })
      })
    })

    context("when the operator is already registered", () => {
      beforeEach(async () => {
        await randomBeacon.connect(operator).registerOperator()
      })

      it("should revert", async () => {
        await expect(
          randomBeacon.connect(operator).registerOperator()
        ).to.be.revertedWith("Operator is already registered")
      })
    })
  })

  describe.only("updateOperatorStatus", () => {
    let tx: ContractTransaction

    beforeEach(async () => {
      tx = await randomBeacon.connect(operator).updateOperatorStatus()
    })

    it("should update operator status", async () => {
      await expect(tx)
        .to.emit(sortitionPoolStub, "OperatorStatusUpdated")
        .withArgs(operator.address)
    })
  })

  describe("isOperatorEligible", () => {
    context("when the operator is eligible to join the sortition pool", () => {
      beforeEach(async () => {
        await sortitionPoolStub.setOperatorEligibility(operator.address, true)
      })

      it("should return true", async () => {
        await expect(await randomBeacon.isOperatorEligible(operator.address)).to
          .be.true
      })
    })

    context(
      "when the operator is not eligible to join the sortition pool",
      () => {
        beforeEach(async () => {
          await sortitionPoolStub.setOperatorEligibility(
            operator.address,
            false
          )
        })

        it("should return false", async () => {
          await expect(await randomBeacon.isOperatorEligible(operator.address))
            .to.be.false
        })
      }
    )
  })
})
