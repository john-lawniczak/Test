// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20}          from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable}         from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

interface ISanctions {
    function isSanctioned(address who) external view returns (bool);
}

/**
 * Two-player skill-game escrow with single-tx match creation.
 */
contract DuelEscrow is Ownable, ReentrancyGuard {
    error InvalidMatch();
    error NotParticipant();
    error AlreadyDeposited();
    error MatchLive();
    error NotReady();
    error AlreadySettled();
    error SecretMismatch();
    error TooEarly();
    error Sanctioned();
    error CommitTaken(uint256 existingId);

    event MatchCreated(
        uint256 indexed id,
        address indexed p1,
        address indexed p2,
        uint256 stake,
        bytes32 commit
    );
    event Deposited(uint256 indexed id, address indexed player);
    event Claimed (uint256 indexed id, address indexed winner, uint256 amount);
    event Refunded(uint256 indexed id, address indexed player, uint256 amount);
    event UnmatchedWithdraw(uint256 indexed id, address indexed player, uint256 amount);
    event DrawAgreed(uint256 indexed id);

    struct Match {
        address p1;
        address p2;
        uint256 stake;
        bytes32 commitHash;
        uint8   deposited;     // bitmask 01 | 10
        uint64  claimDeadline;
        bool    settled;
    }

    IERC20  public immutable token;
    address public immutable treasury;
    uint16  public immutable feeBps;
    ISanctions public immutable OFAC;

    uint32  public joinWindow   = 30 minutes;
    uint32  public playTimeout  = 30 minutes;
    uint256 public nextId       = 1;

    mapping(uint256 => Match)  public matches;
    mapping(bytes32 => uint256) private byCommit;   // commit ⇒ matchId (0 = unused)
    mapping(uint256 => uint8) public drawVotes; // bitmask per match

    constructor(
        IERC20 usdc,
        address feeWallet,
        uint16 _feeBps,
        address ofacAddress
    ) Ownable(msg.sender) {
        require(_feeBps <= 1_000, "fee cap 10%");
        token    = usdc;
        treasury = feeWallet;
        feeBps   = _feeBps;
        OFAC     = ISanctions(ofacAddress);
    }

    /* admin knobs */
    function setJoinWindow(uint32 s) external onlyOwner { joinWindow  = s; }
    function setPlayTimeout(uint32 s) external onlyOwner{ playTimeout = s; }

    /* ------------------------------------------------------------------ */
    /* life-cycle                                                         */
    /* ------------------------------------------------------------------ */

    /// first player both creates the match and escrows their stake
    function createAndDeposit(
        address opponent,
        uint256 stake,
        bytes32 commitHash
    ) external nonReentrant returns (uint256 id) {
        if (OFAC.isSanctioned(msg.sender) || OFAC.isSanctioned(opponent))
            revert Sanctioned();
        if (byCommit[commitHash] != 0)
            revert CommitTaken(byCommit[commitHash]);

        id = nextId++;
        byCommit[commitHash] = id;

        Match storage m = matches[id];
        m.p1         = msg.sender;
        m.p2         = opponent;
        m.stake      = stake;
        m.commitHash = commitHash;
        m.deposited  = 1;

        token.transferFrom(msg.sender, address(this), stake);

        emit MatchCreated(id, msg.sender, opponent, stake, commitHash);
        emit Deposited(id, msg.sender);
    }

    /// second player (or either if re-depositing) escrows stake
    function deposit(uint256 id) external nonReentrant {
        Match storage m = matches[id];
        if (m.p1 == address(0)) revert InvalidMatch();
        if (msg.sender != m.p1 && msg.sender != m.p2) revert NotParticipant();
        if (OFAC.isSanctioned(msg.sender)) revert Sanctioned();

        uint8 flag = msg.sender == m.p1 ? 1 : 2;
        if (m.deposited & flag != 0) revert AlreadyDeposited();
        if (m.settled) revert AlreadySettled();

        token.transferFrom(msg.sender, address(this), m.stake);
        m.deposited |= flag;

        if (m.deposited == 3) {
            m.claimDeadline = uint64(block.timestamp + playTimeout);
        }

        emit Deposited(id, msg.sender);
    }

    function withdrawUnmatched(uint256 id) external nonReentrant {
        Match storage m = matches[id];
        if (m.p1 == address(0))            revert InvalidMatch();
        if (m.deposited == 3)              revert MatchLive();
        if (m.settled)                     revert AlreadySettled();

        uint8 flag = msg.sender == m.p1 ? 1 : msg.sender == m.p2 ? 2 : 0;
        if (flag == 0 || (m.deposited & flag) == 0) revert NotParticipant();

        if (OFAC.isSanctioned(msg.sender)) revert Sanctioned();

        m.settled = true;
        token.transfer(msg.sender, m.stake);
        emit UnmatchedWithdraw(id, msg.sender, m.stake);

        delete byCommit[m.commitHash];
        delete matches[id];
    }

    /// both players can agree to a draw → instant refund
    function agreeDraw(uint256 id) external nonReentrant {
        Match storage m = matches[id];
        if (m.p1 == address(0))           revert InvalidMatch();
        if (m.deposited != 3)             revert NotReady();
        if (m.settled)                    revert AlreadySettled();
        uint8 flag = msg.sender == m.p1 ? 1 : msg.sender == m.p2 ? 2 : 0;
        if (flag == 0) revert NotParticipant();
        drawVotes[id] |= flag;
        if (drawVotes[id] != 3) return; // need both votes

        _refundBoth(id, m);
        emit DrawAgreed(id);
    }

    function _refundBoth(uint256 id, Match storage m) internal {
        if (OFAC.isSanctioned(m.p1) || OFAC.isSanctioned(m.p2)) revert Sanctioned();
        m.settled = true;
        token.transfer(m.p1, m.stake);
        token.transfer(m.p2, m.stake);
        emit Refunded(id, m.p1, m.stake);
        emit Refunded(id, m.p2, m.stake);

        delete byCommit[m.commitHash];
        delete matches[id];
    }

    function claim(uint256 id, bytes32 secret) external nonReentrant {
        Match storage m = matches[id];
        if (m.p1 == address(0))           revert InvalidMatch();
        if (m.deposited != 3)             revert NotReady();
        if (m.settled)                    revert AlreadySettled();
        if (msg.sender != m.p1 && msg.sender != m.p2) revert NotParticipant();
        if (keccak256(abi.encodePacked(secret)) != m.commitHash)
            revert SecretMismatch();
        if (OFAC.isSanctioned(msg.sender)) revert Sanctioned();

        m.settled = true;
        uint256 fee = (m.stake * feeBps) / 10_000;
        uint256 net = m.stake - fee;
        token.transfer(msg.sender, net * 2);
        token.transfer(treasury, fee * 2);
        emit Claimed(id, msg.sender, net * 2);

        delete byCommit[m.commitHash];
        delete matches[id];
    }

    function refund(uint256 id) external nonReentrant {
        Match storage m = matches[id];
        if (m.p1 == address(0))           revert InvalidMatch();
        if (m.deposited != 3)             revert NotReady();
        if (m.settled)                    revert AlreadySettled();
        if (block.timestamp < m.claimDeadline) revert TooEarly();

        _refundBoth(id, m);
    }
}
