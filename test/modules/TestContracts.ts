import _ from 'lodash';
import Web3 from 'web3';
import { Contract } from 'web3-eth-contract';

import { Contracts } from '../../src/modules/Contracts';
import { Provider } from '../../src/lib/types';

// JSON
const jsonFolder = `../../${process.env.COVERAGE ? '.coverage_artifacts' : 'build'}/contracts/`;
const perpetualProxyJson = require(`${jsonFolder}PerpetualProxy.json`);
const perpetualV1Json = require(`${jsonFolder}PerpetualV1.json`);
const p1FundingOracleJson = require(`${jsonFolder}P1FundingOracle.json`);
const p1MakerOracleJson = require(`${jsonFolder}P1MakerOracle.json`);
const p1OrdersJson = require(`${jsonFolder}P1Orders.json`);
const p1DeleveragingJson = require(`${jsonFolder}P1Deleveraging.json`);
const p1LiquidationJson = require(`${jsonFolder}P1Liquidation.json`);
const testLibJson = require(`${jsonFolder}Test_Lib.json`);
const testP1FunderJson = require(`${jsonFolder}Test_P1Funder.json`);
const testP1MonolithJson = require(`${jsonFolder}Test_P1Monolith.json`);
const testP1OracleJson = require(`${jsonFolder}Test_P1Oracle.json`);
const testP1TraderJson = require(`${jsonFolder}Test_P1Trader.json`);
const testTokenJson = require(`${jsonFolder}Test_Token.json`);
const testMakerOracleJson = require(`${jsonFolder}Test_MakerOracle.json`);

export class TestContracts extends Contracts {

  // Test contract instances
  public testLib: Contract;
  public testP1Funder: Contract;
  public testP1Monolith: Contract;
  public testP1Oracle: Contract;
  public testP1Trader: Contract;
  public testToken: Contract;
  public testMakerOracle: Contract;

  constructor(
    provider: Provider,
    networkId: number,
    web3: Web3,
  ) {
    super(provider, networkId, web3);

    // Re-assign the JSON for contracts
    this.contractsList = [];
    this.perpetualProxy = this.addContract(perpetualProxyJson);
    this.perpetualV1 = this.addContract(perpetualV1Json);
    this.p1FundingOracle = this.addContract(p1FundingOracleJson);
    this.p1MakerOracle = this.addContract(p1MakerOracleJson);
    this.p1Orders = this.addContract(p1OrdersJson);
    this.p1Deleveraging = this.addContract(p1DeleveragingJson);
    this.p1Liquidation = this.addContract(p1LiquidationJson);

    // Test contracts
    this.testLib = this.addContract(testLibJson, false);
    this.testP1Funder = this.addContract(testP1FunderJson, false);
    this.testP1Monolith = this.addContract(testP1MonolithJson, false);
    this.testP1Oracle = this.addContract(testP1OracleJson, false);
    this.testP1Trader = this.addContract(testP1TraderJson, false);
    this.testToken = this.addContract(testTokenJson, false);
    this.testMakerOracle = this.addContract(testMakerOracleJson, false);

    this.setProvider(provider, networkId);
    this.setDefaultAccount(this.web3.eth.defaultAccount);
  }
}
