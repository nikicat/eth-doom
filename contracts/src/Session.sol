// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Engine} from "./Engine.sol";

/// @notice Per-game instance: the single source of truth for a live match. Holds
/// the packed world state and immutable engine/map addresses (immutable = a live
/// game's rules can never change underneath it).
///
/// Session keys (M4): a player can't approve a wallet popup every tick, so the
/// `owner` (set once at creation) authorizes ephemeral burner keys with
/// `delegate(sessionKey, expiry)` — a single signature, scoped to this Session and
/// time-boxed. The burner then auto-signs every `submitInput` with no further wallet
/// touches. `owner == address(0)` means the session is **open** (anyone may submit) —
/// used by the differential harness and PoC, where one dev key both deploys and plays.
contract Session {
    Engine public immutable engine;
    address public immutable map;
    /// @notice The player who owns this game and may delegate session keys.
    /// `address(0)` == open: no authorization is enforced (PoC / harness).
    address public immutable owner;

    bytes public state;
    uint256 public tickCount;

    /// @notice sessionKey => unix expiry. 0 = not authorized; submit allowed while
    /// `block.timestamp < expiry`.
    mapping(address => uint64) public sessionKeyExpiry;

    /// @notice Signal that the world advanced; read the new state via `getState()`.
    /// (Emitting the full state blob here cost ~8 gas/byte every tick and nothing
    /// consumes it — the client polls getState(). A lightweight tick signal is enough.)
    event Advanced(uint256 indexed tick);
    /// @notice A session key was authorized (`expiry > 0`) or revoked (`expiry == 0`).
    event Delegated(address indexed sessionKey, uint64 expiry);

    error NotOwner();
    error NotAuthorized();
    error BadExpiry();
    error ZeroKey();
    error SessionOpen();

    constructor(address _engine, address _map, address _owner) {
        engine = Engine(_engine);
        map = _map;
        owner = _owner;
        state = engine.spawn(_map);
        emit Advanced(0);
    }

    /// @notice Authorize `sessionKey` to submit inputs for this game until `expiry`
    /// (unix seconds). One owner signature; the burner then plays popup-free.
    function delegate(address sessionKey, uint64 expiry) external {
        if (owner == address(0)) revert SessionOpen(); // nothing to delegate on an open session
        if (msg.sender != owner) revert NotOwner();
        if (sessionKey == address(0)) revert ZeroKey();
        if (expiry <= block.timestamp) revert BadExpiry();
        sessionKeyExpiry[sessionKey] = expiry;
        emit Delegated(sessionKey, expiry);
    }

    /// @notice Revoke a session key early (it otherwise lapses at its expiry).
    function revoke(address sessionKey) external {
        if (msg.sender != owner) revert NotOwner();
        sessionKeyExpiry[sessionKey] = 0;
        emit Delegated(sessionKey, 0);
    }

    /// @notice May `who` submit inputs? The owner always can; a live session key can;
    /// an open session (owner == 0) lets anyone.
    function isAuthorized(address who) public view returns (bool) {
        if (owner == address(0) || who == owner) return true;
        uint64 expiry = sessionKeyExpiry[who];
        return expiry != 0 && block.timestamp < expiry;
    }

    /// @notice Advance the world one tic with this input (1 input = 1 tick).
    function submitInput(Engine.Cmd calldata cmd) external {
        if (!isAuthorized(msg.sender)) revert NotAuthorized();
        state = engine.tick(state, map, cmd);
        emit Advanced(++tickCount);
    }

    function getState() external view returns (bytes memory) {
        return state;
    }
}
