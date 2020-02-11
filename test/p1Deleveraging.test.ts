import BigNumber from 'bignumber.js';

import initializeWithTestContracts from './helpers/initializeWithTestContracts';
import { expectBalances, mintAndDeposit } from './helpers/balances';
import perpetualDescribe, { ITestContext } from './helpers/perpetualDescribe';
import { buy, sell } from './helpers/trade';
import { expect, expectBN, expectThrow } from './helpers/Expect';
import { address } from '../src';

const initialPrice = new BigNumber(100).shiftedBy(18);
const longBorderlinePrice = new BigNumber(50).shiftedBy(18);
const longUnderwaterPrice = new BigNumber(49.9).shiftedBy(18);
const shortBorderlinePrice = new BigNumber(150).shiftedBy(18);
const shortUnderwaterPrice = new BigNumber(150.1).shiftedBy(18);

let long: address;
let short: address;
let thirdParty: address;
async function init(ctx: ITestContext): Promise<void> {
  await initializeWithTestContracts(ctx);
  long = ctx.accounts[1];
  short = ctx.accounts[2];
  thirdParty = ctx.accounts[3];
}

perpetualDescribe('P1Deleveraging', init, (ctx: ITestContext) => {
  beforeEach(async () => {
    await ctx.perpetual.testing.oracle.setPrice(initialPrice);
    await mintAndDeposit(ctx, long, new BigNumber(500));
    await mintAndDeposit(ctx, short, new BigNumber(500));
    await buy(ctx, long, short, new BigNumber(10), new BigNumber(1000));
    // Starting balances:
    // | account | margin | position | collateralization |
    // |---------+--------+----------+-------------------|
    // | long    |   -500 |       10 |              200% |
    // | short   |   1500 |      -10 |              150% |
  });

  describe('trade()', () => {
    it('returns the expected trade result for partial deleveraging', async () => {
      const amount = new BigNumber(5);
      const tradeResult = await ctx.perpetual.deleveraging.trade(short, long, shortUnderwaterPrice, amount);

      // Partial deleveraging should maintain the ratio of the account being deleveraged.
      expectBN(tradeResult.marginAmount).to.eq(new BigNumber(750));
      expectBN(tradeResult.positionAmount).to.eq(amount);
      expect(tradeResult.isBuy).to.equal(false);
    });
  });

  it('Succeeds fully deleveraging a long position', async () => {
    await ctx.perpetual.testing.oracle.setPrice(longUnderwaterPrice);

    const amount = new BigNumber(10);
    await ctx.perpetual.deleveraging.deleverage(long, short, amount);

    await expectBalances(
      ctx,
      [long, short],
      [new BigNumber(0), new BigNumber(1000)],
      [new BigNumber(0), new BigNumber(0)],
    );
  });

  describe('trade(), via PerpetualV1', () => {
    it('Succeeds fully deleveraging a short position', async () => {
      await ctx.perpetual.testing.oracle.setPrice(shortUnderwaterPrice);

      const amount = new BigNumber(10);
      await ctx.perpetual.deleveraging.deleverage(short, long, amount);

      await expectBalances(
        ctx,
        [long, short],
        [new BigNumber(1000), new BigNumber(0)],
        [new BigNumber(0), new BigNumber(0)],
      );
    });

    it('Cannot deleverage a long position that is not underwater', async () => {
      await ctx.perpetual.testing.oracle.setPrice(longBorderlinePrice);

      const amount = new BigNumber(10);
      await expectThrow(
        ctx.perpetual.deleveraging.deleverage(long, short, amount),
        'Cannot deleverage since maker is not underwater',
      );
    });

    it('Cannot deleverage a short position that is not underwater', async () => {
      await ctx.perpetual.testing.oracle.setPrice(shortBorderlinePrice);

      const amount = new BigNumber(10);
      await expectThrow(
        ctx.perpetual.deleveraging.deleverage(short, long, amount),
        'Cannot deleverage since maker is not underwater',
      );
    });

    it('Cannot deleverage an amount greater than the position of the maker', async () => {
      await ctx.perpetual.testing.oracle.setPrice(shortUnderwaterPrice);

      const amount = new BigNumber(11);
      await expectThrow(
        ctx.perpetual.deleveraging.deleverage(short, long, amount),
        'Maker position is less than the deleverage amount',
      );
    });

    it('Cannot deleverage an amount greater than the position of the taker', async () => {
      await mintAndDeposit(ctx, thirdParty, new BigNumber(10000));
      await sell(ctx, long, thirdParty, new BigNumber(1), new BigNumber(100));

      await ctx.perpetual.testing.oracle.setPrice(shortUnderwaterPrice);

      const amount = new BigNumber(10);
      await expectThrow(
        ctx.perpetual.deleveraging.deleverage(short, long, amount),
        'Taker position is less than the deleverage amount',
      );
    });

    it('Cannot deleverage a long against a long', async () => {
      await mintAndDeposit(ctx, thirdParty, new BigNumber(10000));
      await buy(ctx, short, thirdParty, new BigNumber(20), new BigNumber(500));

      await ctx.perpetual.testing.oracle.setPrice(longUnderwaterPrice);

      const amount = new BigNumber(10);
      await expectThrow(
        ctx.perpetual.deleveraging.deleverage(long, short, amount),
        'Taker position has wrong sign to deleverage this maker',
      );
    });

    it('Cannot deleverage a short against a short', async () => {
      await mintAndDeposit(ctx, thirdParty, new BigNumber(10000));
      await sell(ctx, long, thirdParty, new BigNumber(20), new BigNumber(2500));

      await ctx.perpetual.testing.oracle.setPrice(shortUnderwaterPrice);

      const amount = new BigNumber(10);
      await expectThrow(
        ctx.perpetual.deleveraging.deleverage(short, long, amount),
        'Taker position has wrong sign to deleverage this maker',
      );
    });
  });
});
