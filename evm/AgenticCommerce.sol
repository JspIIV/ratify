// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @title AgenticCommerce
/// @notice ERC-8183 job escrow (https://eips.ethereum.org/EIPS/eip-8183): Open -> Funded -> Submitted -> Terminal.
///         Deployed on GenLayer Chain so that a job's evaluator can be an Intelligent Contract, which calls
///         complete or reject itself, through its Ghost, when its verdict is final. No relayer, no trusted key.
///         Minimal profile: one payment token, no platform fee, and hook must be address(0).
contract AgenticCommerce {
    enum JobStatus { Open, Funded, Submitted, Completed, Rejected, Expired }

    struct Job {
        address client;
        address provider;
        address evaluator;
        string description;
        uint256 budget;
        uint256 expiredAt;
        JobStatus status;
        bytes32 deliverable;
    }

    IERC20 public immutable paymentToken;
    uint256 public jobCounter;
    mapping(uint256 => Job) private jobs;

    event JobCreated(uint256 indexed jobId, address indexed client, address indexed provider, address evaluator, uint256 expiredAt, address hook);
    event ProviderSet(uint256 indexed jobId, address indexed provider);
    event BudgetSet(uint256 indexed jobId, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address indexed provider, uint256 amount);
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);

    error InvalidJob();
    error WrongStatus();
    error Unauthorized();
    error ZeroAddress();
    error ExpiryTooShort();
    error ZeroBudget();
    error ProviderNotSet();
    error BudgetMismatch();
    error HooksNotSupported();
    error NotExpired();
    error TransferFailed();

    constructor(address paymentToken_) {
        if (paymentToken_ == address(0)) revert ZeroAddress();
        paymentToken = IERC20(paymentToken_);
    }

    function _job(uint256 jobId) private view returns (Job storage job) {
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        job = jobs[jobId];
    }

    function createJob(address provider, address evaluator, uint256 expiredAt, string calldata description, address hook)
        external returns (uint256 jobId)
    {
        if (evaluator == address(0)) revert ZeroAddress();
        if (expiredAt <= block.timestamp + 5 minutes) revert ExpiryTooShort();
        if (hook != address(0)) revert HooksNotSupported();
        jobId = ++jobCounter;
        Job storage job = jobs[jobId];
        job.client = msg.sender;
        job.provider = provider;
        job.evaluator = evaluator;
        job.description = description;
        job.expiredAt = expiredAt;
        emit JobCreated(jobId, msg.sender, provider, evaluator, expiredAt, hook);
    }

    function setProvider(uint256 jobId, address provider, bytes calldata) external {
        Job storage job = _job(jobId);
        if (msg.sender != job.client) revert Unauthorized();
        if (job.status != JobStatus.Open || job.provider != address(0)) revert WrongStatus();
        if (provider == address(0)) revert ZeroAddress();
        job.provider = provider;
        emit ProviderSet(jobId, provider);
    }

    function setBudget(uint256 jobId, uint256 amount, bytes calldata) external {
        Job storage job = _job(jobId);
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client && msg.sender != job.provider) revert Unauthorized();
        job.budget = amount;
        emit BudgetSet(jobId, amount);
    }

    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata) external {
        Job storage job = _job(jobId);
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.budget == 0) revert ZeroBudget();
        if (job.provider == address(0)) revert ProviderNotSet();
        if (job.budget != expectedBudget) revert BudgetMismatch();
        job.status = JobStatus.Funded;
        if (!paymentToken.transferFrom(msg.sender, address(this), job.budget)) revert TransferFailed();
        emit JobFunded(jobId, msg.sender, job.budget);
    }

    function submit(uint256 jobId, bytes32 deliverable, bytes calldata) external {
        Job storage job = _job(jobId);
        if (job.status != JobStatus.Funded) revert WrongStatus();
        if (msg.sender != job.provider) revert Unauthorized();
        job.status = JobStatus.Submitted;
        job.deliverable = deliverable;
        emit JobSubmitted(jobId, msg.sender, deliverable);
    }

    function complete(uint256 jobId, bytes32 reason, bytes calldata) external {
        Job storage job = _job(jobId);
        if (job.status != JobStatus.Submitted) revert WrongStatus();
        if (msg.sender != job.evaluator) revert Unauthorized();
        job.status = JobStatus.Completed;
        emit JobCompleted(jobId, msg.sender, reason);
        if (!paymentToken.transfer(job.provider, job.budget)) revert TransferFailed();
        emit PaymentReleased(jobId, job.provider, job.budget);
    }

    function reject(uint256 jobId, bytes32 reason, bytes calldata) external {
        Job storage job = _job(jobId);
        JobStatus s = job.status;
        if (s == JobStatus.Open) {
            if (msg.sender != job.client) revert Unauthorized();
        } else if (s == JobStatus.Funded || s == JobStatus.Submitted) {
            if (msg.sender != job.evaluator) revert Unauthorized();
        } else {
            revert WrongStatus();
        }
        job.status = JobStatus.Rejected;
        emit JobRejected(jobId, msg.sender, reason);
        if (s != JobStatus.Open) {
            if (!paymentToken.transfer(job.client, job.budget)) revert TransferFailed();
            emit Refunded(jobId, job.client, job.budget);
        }
    }

    function claimRefund(uint256 jobId) external {
        Job storage job = _job(jobId);
        if (job.status != JobStatus.Funded && job.status != JobStatus.Submitted) revert WrongStatus();
        if (block.timestamp < job.expiredAt) revert NotExpired();
        job.status = JobStatus.Expired;
        emit JobExpired(jobId);
        if (!paymentToken.transfer(job.client, job.budget)) revert TransferFailed();
        emit Refunded(jobId, job.client, job.budget);
    }

    /// The job, flat, for readers that decode static tuples (an Intelligent Contract among them).
    function jobCore(uint256 jobId) external view returns (
        address client, address provider, address evaluator, uint8 status, uint256 budget, uint256 expiredAt, bytes32 deliverable
    ) {
        Job storage job = _job(jobId);
        return (job.client, job.provider, job.evaluator, uint8(job.status), job.budget, job.expiredAt, job.deliverable);
    }

    function jobDescription(uint256 jobId) external view returns (string memory) {
        return _job(jobId).description;
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        return _job(jobId);
    }
}
