// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ArcBountyJudge
/// @notice Commit-reveal bounty with off-chain AI review, ported to Arc.
/// @dev On Arc, the native token is USDC (18 decimals). msg.value and all
///      reward amounts in this contract are native USDC in 18 decimals.
///      Never mix them with the ERC-20 USDC interface (6 decimals).
contract ArcBountyJudge {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    struct Submission {
        address submitter;
        bytes32 commitment;
        string answer;
        bool revealed;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward; // native USDC, 18 decimals
        uint256 deadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        bytes32 reviewHash; // keccak256 of the off-chain AI review
        string reviewURI; // where the full review can be read (IPFS, gist, ...)
        uint256 winnerIndex;
        uint256 revealedCount;
        Submission[] submissions;
    }

    mapping(uint256 => Bounty) private bounties;

    // bountyId => participant => submission index + 1
    mapping(uint256 => mapping(address => uint256)) public submissionIndexPlusOne;

    // Pull payments: native transfers can revert on Arc (e.g. blocklist),
    // so rewards are credited here and withdrawn by the recipient.
    mapping(address => uint256) public pendingWithdrawals;

    event BountyCreated(uint256 indexed bountyId, address indexed owner, string title, uint256 reward, uint256 deadline, uint256 revealDeadline);
    event CommitmentSubmitted(uint256 indexed bountyId, uint256 indexed submissionIndex, address indexed submitter, bytes32 commitment);
    event AnswerRevealed(uint256 indexed bountyId, uint256 indexed submissionIndex, address indexed submitter);
    event ReviewRecorded(uint256 indexed bountyId, bytes32 reviewHash, string reviewURI);
    event WinnerFinalized(uint256 indexed bountyId, uint256 indexed winnerIndex, address indexed winner, uint256 reward);
    event BountyRefunded(uint256 indexed bountyId, address indexed owner, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    // ---------------------------------------------------------------------
    // 1. Create: reward is sent as native USDC (msg.value)
    // ---------------------------------------------------------------------
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 deadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(deadline > block.timestamp, "deadline must be future");
        require(revealDeadline > deadline, "reveal deadline must be later");

        bountyId = nextBountyId++;
        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.deadline = deadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, deadline, revealDeadline);
    }

    // ---------------------------------------------------------------------
    // 2. Commit: keccak256(abi.encode(answer, salt, participant, bountyId))
    // ---------------------------------------------------------------------
    function submitCommitment(uint256 bountyId, bytes32 commitment) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        require(block.timestamp < bounty.deadline, "submissions closed");
        require(commitment != bytes32(0), "empty commitment");
        require(submissionIndexPlusOne[bountyId][msg.sender] == 0, "already submitted");
        require(bounty.submissions.length < MAX_SUBMISSIONS, "too many submissions");

        bounty.submissions.push(Submission({submitter: msg.sender, commitment: commitment, answer: "", revealed: false}));
        uint256 submissionIndex = bounty.submissions.length - 1;
        submissionIndexPlusOne[bountyId][msg.sender] = submissionIndex + 1;

        emit CommitmentSubmitted(bountyId, submissionIndex, msg.sender, commitment);
    }

    // ---------------------------------------------------------------------
    // 3. Reveal
    // ---------------------------------------------------------------------
    function revealAnswer(uint256 bountyId, string calldata answer, bytes32 salt) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        require(block.timestamp >= bounty.deadline, "reveal not started");
        require(block.timestamp < bounty.revealDeadline, "reveal period ended");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 indexPlusOne = submissionIndexPlusOne[bountyId][msg.sender];
        require(indexPlusOne != 0, "no commitment");
        uint256 submissionIndex = indexPlusOne - 1;
        Submission storage submission = bounty.submissions[submissionIndex];
        require(!submission.revealed, "already revealed");

        require(
            keccak256(abi.encode(answer, salt, msg.sender, bountyId)) == submission.commitment,
            "invalid answer or salt"
        );

        submission.answer = answer;
        submission.revealed = true;
        bounty.revealedCount++;

        emit AnswerRevealed(bountyId, submissionIndex, msg.sender);
    }

    // ---------------------------------------------------------------------
    // 4. Record off-chain AI review (Ritual's LLM precompile is not on Arc)
    // ---------------------------------------------------------------------
    function recordReview(uint256 bountyId, bytes32 reviewHash, string calldata reviewURI)
        external
        bountyExists(bountyId)
        onlyOwner(bountyId)
    {
        Bounty storage bounty = bounties[bountyId];
        require(block.timestamp >= bounty.revealDeadline, "reveal period not ended");
        require(!bounty.judged, "already judged");
        require(bounty.revealedCount > 0, "no revealed submissions");
        require(reviewHash != bytes32(0), "empty review hash");

        bounty.judged = true;
        bounty.reviewHash = reviewHash;
        bounty.reviewURI = reviewURI;

        emit ReviewRecorded(bountyId, reviewHash, reviewURI);
    }

    // ---------------------------------------------------------------------
    // 5. Finalize: credit the winner (pull payment)
    // ---------------------------------------------------------------------
    function finalizeWinner(uint256 bountyId, uint256 winnerIndex) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid winner index");
        require(bounty.submissions[winnerIndex].revealed, "winner did not reveal");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;
        pendingWithdrawals[winner] += reward;

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    /// @notice If nobody revealed a valid answer, the owner can reclaim the reward.
    function refundIfNoReveals(uint256 bountyId) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        require(block.timestamp >= bounty.revealDeadline, "reveal period not ended");
        require(bounty.revealedCount == 0, "has revealed submissions");
        require(!bounty.finalized, "already finalized");

        bounty.finalized = true;
        uint256 amount = bounty.reward;
        bounty.reward = 0;
        pendingWithdrawals[msg.sender] += amount;

        emit BountyRefunded(bountyId, msg.sender, amount);
    }

    /// @notice Withdraw credited native USDC.
    function withdraw() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "nothing to withdraw");
        pendingWithdrawals[msg.sender] = 0; // effects before interaction

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");

        emit Withdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------
    function getBounty(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 deadline,
            bool judged,
            bool finalized,
            uint256 submissionCount,
            uint256 winnerIndex
        )
    {
        Bounty storage b = bounties[bountyId];
        return (b.owner, b.title, b.rubric, b.reward, b.deadline, b.judged, b.finalized, b.submissions.length, b.winnerIndex);
    }

    function getRevealStatus(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (uint256 revealDeadline, uint256 revealedCount)
    {
        Bounty storage b = bounties[bountyId];
        return (b.revealDeadline, b.revealedCount);
    }

    function getReview(uint256 bountyId) external view bountyExists(bountyId) returns (bytes32 reviewHash, string memory reviewURI) {
        Bounty storage b = bounties[bountyId];
        return (b.reviewHash, b.reviewURI);
    }

    function getSubmission(uint256 bountyId, uint256 index)
        external
        view
        bountyExists(bountyId)
        returns (address submitter, bytes32 commitment, string memory answer, bool revealed)
    {
        Bounty storage b = bounties[bountyId];
        require(index < b.submissions.length, "invalid index");
        Submission storage s = b.submissions[index];
        return (s.submitter, s.commitment, s.answer, s.revealed);
    }
}
