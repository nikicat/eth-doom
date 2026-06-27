// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Session} from "./Session.sol";

/// @notice Spins up game instances. Each call deploys a fresh `Session` bound to an
/// `(engine, map)` pair and records it, so many concurrent matches share one engine
/// and one map deployment, and clients/indexers can discover live games from the
/// `CreatedSession` events.
///
/// Full `Session` deploys, deliberately NOT EIP-1167 minimal-proxy clones: a clone
/// can't run a constructor or use `immutable`, so it would have to hold `engine`/`map`
/// in storage and read them with two cold `SLOAD`s on EVERY `submitInput`. Over the
/// thousands of ticks a real game runs, that per-tick cost dwarfs the one-time clone
/// saving — so `immutable engine`/`map` (set once in the constructor, never changeable
/// underneath a live game) plus a full deploy is the cheaper choice in aggregate.
contract SessionFactory {
    /// @notice Every session this factory has created, in order.
    address[] public sessions;

    event CreatedSession(
        address indexed session, address indexed engine, address indexed map, address creator
    );

    /// @notice Deploy a new game instance for `(engine, map)`, owned by the caller,
    /// and record it. The owner may then `delegate` a session key for popup-free play.
    function createSession(address engine, address map) external returns (address session) {
        session = address(new Session(engine, map, msg.sender));
        sessions.push(session);
        emit CreatedSession(session, engine, map, msg.sender);
    }

    function sessionCount() external view returns (uint256) {
        return sessions.length;
    }
}
