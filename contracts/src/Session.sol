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

    /// @notice Signal that the world advanced; read the new state via `getState()`.
    /// (Emitting the full state blob here cost ~8 gas/byte every tick and nothing
    /// consumes it — the client polls getState(). A lightweight tick signal is enough.)
    event Advanced(uint256 indexed tick);

    constructor(address _engine, address _map) {
        engine = Engine(_engine);
        map = _map;
        state = engine.spawn(_map);
        emit Advanced(0);
    }

    /// @notice Advance the world one tic with this input (1 input = 1 tick).
    function submitInput(Engine.Cmd calldata cmd) external {
        state = engine.tick(state, map, cmd);
        emit Advanced(++tickCount);
    }

    function getState() external view returns (bytes memory) {
        return state;
    }
}
