import { default as axios } from 'axios';
import BigNumber from 'bignumber.js';
import {
  ApiAccount,
  ApiFundingRates,
  ApiHistoricalFundingRates,
  ApiIndexPrice,
  ApiMarketMessage,
  ApiMarketName,
  ApiOptions,
  ApiOrder,
  ApiOrderOnOrderbook,
  ApiSide,
  BigNumberable,
  Fee,
  Order,
  Price,
  SignedOrder,
  SigningMethod,
  address,
} from '../lib/types';
import { Orders } from './Orders';

const FOUR_WEEKS_IN_SECONDS = 60 * 60 * 24 * 28;
const DEFAULT_API_ENDPOINT = 'https://api.dydx.exchange';
const DEFAULT_API_TIMEOUT = 10000;

export class Api {
  private endpoint: String;
  private perpetualOrders: Orders;
  private timeout: number;

  constructor(
    perpetualOrders: Orders,
    apiOptions: ApiOptions = {},
  ) {
    this.endpoint = apiOptions.endpoint || DEFAULT_API_ENDPOINT;
    this.timeout = apiOptions.timeout || DEFAULT_API_TIMEOUT;
    this.perpetualOrders = perpetualOrders;
  }

  // ============ Managing Orders ============

  public async placePerpetualOrder({
    order: {
      side,
      amount,
      price,
      maker,
      taker,
      expiration = new BigNumber(FOUR_WEEKS_IN_SECONDS),
      limitFee,
      salt,
    },
    market,
    fillOrKill,
    postOnly,
    clientId,
    cancelId,
    cancelAmountOnRevert,
  }: {
    order: {
      side: ApiSide,
      amount: BigNumberable,
      price: BigNumberable,
      maker: address,
      taker: address,
      expiration: BigNumberable,
      limitFee?: BigNumberable,
      salt?: BigNumberable,
    },
    market: ApiMarketName,
    fillOrKill?: boolean,
    postOnly?: boolean,
    clientId?: string,
    cancelId?: string,
    cancelAmountOnRevert?: boolean,
  }): Promise<{ order: ApiOrder }> {
    const order: SignedOrder = await this.createPerpetualOrder({
      market,
      side,
      amount,
      price,
      maker,
      taker,
      expiration,
      postOnly,
      limitFee,
      salt,
    });

    return this.submitPerpetualOrder({
      order,
      market,
      fillOrKill,
      postOnly,
      cancelId,
      clientId,
      cancelAmountOnRevert,
    });
  }

  /**
   * Creates but does not place a signed perpetualOrder
   */
  async createPerpetualOrder({
    market,
    side,
    amount,
    price,
    maker,
    taker,
    expiration,
    postOnly,
    limitFee,
    salt,
  }: {
    market: ApiMarketName,
    side: ApiSide,
    amount: BigNumberable,
    price: BigNumberable,
    maker: address,
    taker: address,
    expiration: BigNumberable,
    postOnly: boolean,
    limitFee?: BigNumberable,
    salt?: BigNumberable,
  }): Promise<SignedOrder> {
    if (!Object.values(ApiMarketName).includes(market)) {
      throw new Error(`market: ${market} is invalid`);
    }
    if (!Object.values(ApiSide).includes(side)) {
      throw new Error(`side: ${side} is invalid`);
    }

    const amountNumber: BigNumber = new BigNumber(amount);
    const perpetualLimitFee: Fee = limitFee
      ? new Fee(limitFee)
      : this.perpetualOrders.getFeeForOrder(amountNumber, !postOnly);

    const realExpiration: BigNumber = getRealExpiration(expiration);
    const order: Order = {
      maker,
      taker,
      limitFee: perpetualLimitFee,
      isBuy: side === ApiSide.BUY,
      isDecreaseOnly: false,
      amount: amountNumber,
      limitPrice: new Price(price),
      triggerPrice: new Price('0'),
      expiration: realExpiration,
      salt: salt ? new BigNumber(salt) : generatePseudoRandom256BitNumber(),
    };

    const typedSignature: string = await this.perpetualOrders.signOrder(
      order,
      SigningMethod.Hash,
    );

    return {
      ...order,
      typedSignature,
    };
  }

  /**
   * Submits an already signed perpetualOrder
   */
  public async submitPerpetualOrder({
    order,
    market,
    fillOrKill = false,
    postOnly = false,
    cancelId,
    clientId,
    cancelAmountOnRevert,
  }: {
    order: SignedOrder,
    market: ApiMarketName,
    fillOrKill?: boolean,
    postOnly?: boolean,
    cancelId?: string,
    clientId?: string,
    cancelAmountOnRevert?: boolean,
  }): Promise<{ order: ApiOrder }> {
    const jsonOrder = jsonifyPerpetualOrder(order);

    const data: any = {
      fillOrKill,
      postOnly,
      clientId,
      cancelId,
      cancelAmountOnRevert,
      market,
      order: jsonOrder,
    };

    const response = await axios({
      data,
      method: 'post',
      url: `${this.endpoint}/v2/orders`,
      timeout: this.timeout,
    });

    return response.data;
  }

  public async cancelOrder({
    orderId,
    maker,
  }: {
    orderId: string,
    maker: address,
  }): Promise<{ order: ApiOrder }> {
    const signature = await this.perpetualOrders.signCancelOrderByHash(
      orderId,
      maker,
      SigningMethod.Hash,
    );

    const response = await axios({
      url: `${this.endpoint}/v2/orders/${orderId}`,
      method: 'delete',
      headers: {
        authorization: `Bearer ${signature}`,
      },
      timeout: this.timeout,
    });

    return response.data;
  }

  // ============ Getters ============

  public async getMarkets():
    Promise<{ markets: ApiMarketMessage[] }> {
    const response = await axios({
      url: `${this.endpoint}/v1/perpetual-markets`,
      method: 'get',
      timeout: this.timeout,
    });
    return response.data;
  }

  public async getAccountBalances({
    accountOwner,
  }: {
    accountOwner: address,
  }): Promise<ApiAccount> {
    const response = await axios({
      url: `${this.endpoint}/v1/perpetual-accounts/${accountOwner}`,
      method: 'get',
      timeout: this.timeout,
    });

    return response.data;
  }

  public async getOrderbook({
    market,
  }: {
    market: ApiMarketName,
  }): Promise<{ bids: ApiOrderOnOrderbook[], asks: ApiOrderOnOrderbook[] }> {
    const response = await axios({
      url: `${this.endpoint}/v1/orderbook/${market}`,
      method: 'get',
      timeout: this.timeout,
    });

    return response.data;
  }

  // ============ Funding Getters ============

  /**
   * Get the current and predicted funding rates.
   *
   * IMPORTANT: The `current` value returned by this function is not active until it has been mined
   * on-chain, which may not happen for some period of time after the start of the hour. To get the
   * funding rate that is currently active on-chain, use the getMarkets() function.
   *
   * The `current` rate is updated each hour, on the hour. The `predicted` rate is updated each
   * minute, on the minute, and may be null if no premiums have been calculated since the last
   * funding rate update.
   *
   * Params:
   * * markets (optional): If present, will limit the results to the specified markets.
   */
  public async getFundingRates({
    markets,
  }: {
    markets?: ApiMarketName[],
  } = {}): Promise<{ [market: string]: ApiFundingRates }> {
    const response = await axios({
      url: `${this.endpoint}/v1/funding-rates`,
      method: 'get',
      timeout: this.timeout,
      params: markets ? { markets } : {},
    });

    return response.data;
  }

  /**
   * Get historical funding rates.
   *
   * Params:
   * * markets (optional): If present, will limit the results to the specified markets.
   */
  public async getHistoricalFundingRates({
    markets,
  }: {
    markets?: ApiMarketName[],
  } = {}): Promise<{ [market: string]: ApiHistoricalFundingRates }> {
    const response = await axios({
      url: `${this.endpoint}/v1/historical-funding-rates`,
      method: 'get',
      timeout: this.timeout,
      params: markets ? { markets } : {},
    });

    return response.data;
  }

  /**
   * Get the index price used in the funding rate calculation.
   *
   * Params:
   * * markets (optional): If present, will limit the results to the specified markets.
   */
  public async getFundingIndexPrice({
    markets,
  }: {
    markets?: ApiMarketName[],
  } = {}): Promise<{ [market: string]: ApiIndexPrice }> {
    const response = await axios({
      url: `${this.endpoint}/v1/index-price`,
      method: 'get',
      timeout: this.timeout,
      params: markets ? { markets } : {},
    });

    return response.data;
  }
}

function generatePseudoRandom256BitNumber(): BigNumber {
  const MAX_DIGITS_IN_UNSIGNED_256_INT = 78;

  // BigNumber.random returns a pseudo-random number between 0 & 1 with a passed in number of
  // decimal places.
  // Source: https://mikemcl.github.io/bignumber.js/#random
  const randomNumber = BigNumber.random(MAX_DIGITS_IN_UNSIGNED_256_INT);
  const factor = new BigNumber(10).pow(MAX_DIGITS_IN_UNSIGNED_256_INT - 1);
  const randomNumberScaledTo256Bits = randomNumber.times(factor).integerValue();
  return randomNumberScaledTo256Bits;
}

function jsonifyPerpetualOrder(order: SignedOrder) {
  return {
    isBuy: order.isBuy,
    isDecreaseOnly: order.isDecreaseOnly,
    amount: order.amount.toFixed(0),
    limitPrice: order.limitPrice.value.toString(),
    triggerPrice: order.triggerPrice.value.toString(),
    limitFee: order.limitFee.value.toString(),
    maker: order.maker,
    taker: order.taker,
    expiration: order.expiration.toFixed(0),
    typedSignature: order.typedSignature,
    salt: order.salt.toFixed(0),
  };
}

function getRealExpiration(expiration: BigNumberable): BigNumber {
  return new BigNumber(expiration).eq(0) ?
    new BigNumber(0)
    : new BigNumber(Math.round(new Date().getTime() / 1000)).plus(
      new BigNumber(expiration),
    );
}
