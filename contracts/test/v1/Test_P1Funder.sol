/*

    Copyright 2020 dYdX Trading Inc.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

*/

pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

import { I_P1Funder } from "../../protocol/v1/intf/I_P1Funder.sol";


/**
 * @title Test_P1Funder
 * @author dYdX
 *
 * P1Funder for testing
 */
contract Test_P1Funder is
    I_P1Funder
{
    function getFunding(uint256 timestamp)
        external
        view
        returns (bool, uint256)
    {
        // TODO
        return false, _TIMESTAMP_;
    }
}
