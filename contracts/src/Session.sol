// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Engine} from "./Engine.sol";

/// @notice Per-game instance: the single source of truth for a live match. Holds
/// the packed world state and immutable engine/map addresses (immutable = a live
/// game's rules can never change underneath it). M1: single player, no session keys.
contract Session {
    Engine public immutable engine;
    address public immutable map;

    bytes public state;
    uint256 public tickCount;

    event StateDelta(uint256 indexed tick, bytes state);

    constructor(address _engine, address _map) {
        engine = Engine(_engine);
        map = _map;
        state = engine.spawn(_map);
        emit StateDelta(0, state);
    }

    /// @notice Advance the world one tic with this input (1 input = 1 tick).
    function submitInput(Engine.Cmd calldata cmd) external {
        bytes memory ns = engine.tick(state, map, cmd);
        state = ns;
        emit StateDelta(++tickCount, ns);
    }

    function getState() external view returns (bytes memory) {
        return state;
    }
}
