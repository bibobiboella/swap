import { INTEGERS } from '../src/lib/Constants';
import {
  BaseValue,
  BigNumberable,
  FundingRate,
  Price,
  address,
} from '../src/lib/types';
import { fastForward } from './helpers/EVM';
import {
  expect,
  expectBaseValueEqual,
  expectThrow,
} from './helpers/Expect';
import initializePerpetual from './helpers/initializePerpetual';
import perpetualDescribe, { ITestContext } from './helpers/perpetualDescribe';

const oraclePrice = new Price(100);

let admin: address;

async function init(ctx: ITestContext): Promise<void> {
  await initializePerpetual(ctx);
  admin = ctx.accounts[0];
  await ctx.perpetual.testing.oracle.setPrice(oraclePrice);
}

perpetualDescribe('P1FundingOracle', init, (ctx: ITestContext) => {

  describe('getFunding()', () => {

    it('initially returns zero', async () => {
      await expectFunding(1000, 0);
    });

    it('gets funding as a function of time elapsed', async () => {
      // Funding is represented as an annual rate.
      await ctx.perpetual.fundingOracle.setFundingRate(
        new FundingRate('1e-10'),
        { from: admin },
      );

      await expectFunding(INTEGERS.ONE_YEAR_IN_SECONDS.times(1000), '1e-7');
      await expectFunding(INTEGERS.ONE_YEAR_IN_SECONDS.times(10000), '1e-6');
      await expectFunding(INTEGERS.ONE_YEAR_IN_SECONDS.times(100000), '1e-5');
    });
  });

  describe('setFundingRate()', () => {

    it('sets a positive funding rate', async () => {
      await setFundingRate(new FundingRate('1e-10'));
      await setFundingRate(new FundingRate('1e-15'));

      // Set to max value, while obeying the per-update speed limit.
      await setFundingRate(FundingRate.fromDailyRate('0.01'));
      await setFundingRate(FundingRate.fromDailyRate('0.02'));
    });

    it('sets a negative funding rate', async () => {
      await setFundingRate(new FundingRate('-1e-10'));
      await setFundingRate(new FundingRate('-1e-15'));

      // Set to min value, while obeying the per-update speed limit.
      await setFundingRate(FundingRate.fromDailyRate('-0.01'));
      await setFundingRate(FundingRate.fromDailyRate('-0.02'));
    });

    it('sets a very small or zero funding rate', async () => {
      await setFundingRate(new FundingRate('-1e-16'));
      await setFundingRate(new FundingRate('-1e-18'));
      await setFundingRate(new FundingRate(0));
    });

    it('fails if not called by the contract owner', async () => {
      await expectThrow(
        ctx.perpetual.fundingOracle.setFundingRate(new FundingRate('1e-10')),
        'Ownable: caller is not the owner',
      );
    });
  });

  async function expectFunding(
    timeDelta: BigNumberable,
    expectedFunding: BigNumberable,
  ): Promise<void> {
    const funding: BaseValue = await ctx.perpetual.fundingOracle.getFunding(timeDelta);
    expectBaseValueEqual(funding, new BaseValue(expectedFunding));
  }

  /**
   * Set the funding rate and verify the emitted logs.
   */
  async function setFundingRate(
    fundingRate: FundingRate,
  ): Promise<void> {
    // Fast forward so that the speed limit on changes to funding rate does not take effect.
    await fastForward(INTEGERS.ONE_HOUR_IN_SECONDS.toNumber());

    // Verify the return value is as expected.
    const simulatedResult = await ctx.perpetual.fundingOracle.getBoundedFundingRate(
      fundingRate,
      { from: admin },
    );
    expectBaseValueEqual(simulatedResult, fundingRate, 'simulated result');

    // Set the funding rate.
    const txResult = await ctx.perpetual.fundingOracle.setFundingRate(fundingRate, { from: admin });

    // Check logs.
    const logs = ctx.perpetual.logs.parseLogs(txResult);
    expect(logs.length, 'logs length').to.equal(1);
    expect(logs[0].name).to.equal('LogFundingRateUpdated');
    expectBaseValueEqual(
      logs[0].args.fundingRate.baseValue,
      fundingRate,
      'funding rate',
    );
  }
});
