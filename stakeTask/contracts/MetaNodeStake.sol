// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "hardhat/console.sol";

contract MetaNodeStake is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {

    using SafeERC20 for IERC20;
    using Math for uint256;

    // user结构体
    struct User {
        // 用户质押代币数
        uint256 stAmount;
        // 已分配的奖励币数量
        uint256 finishedRewardToken;
        // 待领取的奖励币数量（当用户更新了质押代币数时，按）
        uint256 pendingRewardToken;
        // 解质押请求列表，每个请求包含解质押数量和解锁区块
        Request[] requestes;
    }

    // 请求结构体
    struct Request {
        uint256 amount;
        uint256 unlockBlocks;
    }

    // 质押池
    struct Pool {
        // 质押token地址
        address stTokenAddress;
        // 权重
        uint256 poolWeight;
        // 最后一次计算奖励的区块号。
        uint256 lastRewardBlock;
        // 每个质押代币累积的奖励币数量。
        uint256 accRewardTokenPerST;
        // 池中质押代币总数
        uint256 stTokenAmount;
        // 最小质押金额。
        uint256 minDepositAmount;
        // 解除质押的锁定区块数。
        uint256 unstakeLockedBlocks;
    }

    bytes32 public constant ADMIN_ROLE = keccak256("admin_role");
    bytes32 public constant UPGRADE_ROLE = keccak256("upgrade_role");

    uint256 public constant ETH_PID = 0;

    // 奖励的token
    IERC20 public RewardToken;

    // 开始区块（计算收益）
    uint256 private _startBlock;
    // 结束区块（计算收益）
    uint256 private _endBlock;
    // 每个区块产出多少个奖励token
    uint256 private _rewardTokenPerBlock;

    // 总质押池权重
    uint256 private _totalPoolsWeight;

    // 用户质押信息
    mapping(uint256 pid => mapping(address => User)) private _user;
    
    // 质押池。第一个池固定为ETH,pid: ETH_PID
    Pool[] private _pool;

    // 质押开关
    bool public pauseDeposit;

    // 解除质押开关
    bool public pauseUnstake;

    // 提现开关
    bool public pauseWithdraw;

    // 更新池信息事件
    event UpdatePool(uint256 indexed pid, uint256 lastRewardBlock, uint256 stTokenRewardToken);

    // 质押事件
    event Deposit(uint256 indexed pid, address indexed user, uint256 amount);

    // 撤回质押事件
    event Unstake(uint256 indexed pid, address indexed user, uint256 amount);

    // 提现事件
    event Withdraw(uint256 indexed pid, address indexed user, uint256 sumWithdraw, uint256 blockNumber);

    // 更换奖励币事件
    event SetRewardToken(IERC20 indexed rewardToken);

    // 质押开关事件
    event SetPauseDeposit(bool indexed isPause);

    // 解除质押开关事件
    event SetPauseUnstake(bool indexed isPause);

    // 提现开关事件
    event SetPauseWithdraw(bool indexed isPause);
    
    event SetPauseClaim(bool indexed isPause);

    event SetStartBlock(uint256 indexed startBlock);

    event SetEndBlock(uint256 indexed endBlock);

    event SetRewardTokenPerBlock(uint256 indexed rewardTokenBlock);

    event SetPoolWeight(uint256 indexed pid, uint256 indexed poolWeight, uint256 totalPoolWeight);

    event Claim(uint256 indexed pid, address user, uint256 peedingToken);

    modifier checkPid(uint256 pid) {
        require(pid < _pool.length, "invalid pid");
        _;
    }

    function initialize(IERC20 metaNode, uint256 startBlock, uint256 endBlock, uint256 metaNodePerBlock) initializer public {
        require(startBlock <= endBlock && metaNodePerBlock > 0, "invalid parameters");
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ADMIN_ROLE, _msgSender());
        _grantRole(UPGRADE_ROLE, _msgSender());

        RewardToken = metaNode;
        _startBlock = startBlock;
        _endBlock = endBlock;
        _rewardTokenPerBlock = metaNodePerBlock;

        // ETH 池初始化
        // 需要初始化 lastRewardBlock ，后面计算会直接使用。取 max(block.number, _startBlock)
        uint256 lastRewardBlock = block.number > _startBlock ? block.number : _startBlock;
        _pool.push(Pool({
                stTokenAddress: address(0),
                poolWeight: 100,
                minDepositAmount: 0.1 * (1 ether),
                unstakeLockedBlocks: 10,
                lastRewardBlock: lastRewardBlock,
                accRewardTokenPerST: 0,
                stTokenAmount: 0
            }));
    }

    function depositETH() public payable whenNotPaused returns (bool) {
        // 异常处理: 质押数量低于最小质押要求时拒绝交易。
        Pool storage pool = _pool[ETH_PID];
        uint256 amount = msg.value;
        console.log("amount: ", amount);
        console.log("pool.minDepositAmount: ", pool.minDepositAmount);
        require(amount > pool.minDepositAmount, "AmountTooSmall");        
        
        _deposit(ETH_PID, amount);
        return true;
    }

    /**
     * 质押 ERC20
     * @param pid 池id
     * @param amount 质押金额
     */
    function deposit(uint pid, uint256 amount) public whenNotPaused checkPid(pid) returns (bool) {
        // 异常处理: 质押数量低于最小质押要求时拒绝交易。
        Pool storage pool = _pool[pid];
        // require(amount > pool.minDepositAmount, "AmountTooSmall");
        
        if (amount > 0) {
            // 将质押的代币转移到本合约
            IERC20(pool.stTokenAddress).safeTransferFrom(_msgSender(), address(this), amount);
        }
        
        _deposit(pid, amount);
        return true;
    }


    /**
     * 质押
     */
    function _deposit(uint _pid, uint256 _amount) internal {
        Pool storage pool = _pool[_pid];
        User storage user = _user[_pid][_msgSender()];

        // 更新池奖励因子信息
        updatePool(_pid);
        
        // 1 计算未领取奖励
        if (user.stAmount > 0) {
            // 计算用户奖励（池每个质押获得的奖励因子已更新）; 去除缩放因子
            uint256 accSt = user.stAmount * (pool.accRewardTokenPerST) / (1 ether);

            // 减去已获得的奖励
            uint peedingRewardToken = accSt - user.finishedRewardToken;
            if (peedingRewardToken > 0) {
                user.pendingRewardToken += peedingRewardToken;
            }
        }

        // 2 更新质押信息
        // 2.1 更新用户质押信息
        user.stAmount += _amount;
        // 2.2 更新池质押信息
        pool.stTokenAmount += _amount;

        // 3 计算已分配奖励（在当前检查点下，我质押的数量应该获得的奖励）
        uint256 finishedRewardToken = user.stAmount * (pool.accRewardTokenPerST) / (1 ether);
        user.finishedRewardToken = finishedRewardToken;

        emit Deposit(_pid, _msgSender(), _amount);
    }

    /**
     * 解除质押
     * @param pid 池id
     * @param amount 质押金额
     */
    function unstake(uint256 pid, uint256 amount) public whenNotPaused checkPid(pid) returns (bool) {
        User storage user = _user[pid][_msgSender()];
        Pool storage pool = _pool[pid];

        require(amount < user.stAmount, "your st amount less than amount");

        // 更新池信息
        updatePool(pid);

        // 计算待提取奖励
        uint256 pendingRewardToken = user.stAmount * pool.accRewardTokenPerST / (1 ether) - user.finishedRewardToken;
        if (pendingRewardToken > 0) {
            user.pendingRewardToken += pendingRewardToken;
        }

        // 将提取请求放入user的请求列表
        if (amount > 0) {
            user.stAmount -= amount;
            user.requestes.push(Request({
                amount: amount,
                unlockBlocks: block.number + pool.unstakeLockedBlocks
            }));
        }

        // 更新质押数
        pool.stTokenAmount -= amount;
        user.finishedRewardToken = user.stAmount * pool.accRewardTokenPerST / (1 ether);
    
        emit Unstake(pid, _msgSender(), amount);
        return true;
    }

    /**
     * 质押提现
     * @param pid 池id
     */
    function withdraw(uint256 pid) public whenNotPaused checkPid(pid) returns (bool) {
        Pool storage pool = _pool[pid];
        User storage user = _user[pid][_msgSender()];
        if (user.requestes.length == 0) {
            return true;
        }

        // 1 计算提现金额
        // 需要删除的请求，请求按区块高度顺序
        uint256 popIndex;
        // 待提现总代币数
        uint256 sumWithdraw;
        for(uint256 i = 0; i < user.requestes.length; i++) {
            Request memory req = user.requestes[i];
            if(req.unlockBlocks > block.number) {
                break;
            }
            sumWithdraw += req.amount;
            popIndex++;
        }

        // 将 popIndex 之后的元素移动到数组开头
        uint256 newLength = user.requestes.length - popIndex;
        for (uint i = 0; i < newLength; i++) {
            user.requestes[i] = user.requestes[popIndex + i];
        }
        
        // 截断数组
        while (user.requestes.length > newLength) {
            user.requestes.pop();
        }
        
        // 2 提现
        if(sumWithdraw > 0) {
            // 2.1 质押的ETH
            if(pool.stTokenAddress == address(0)) {
                _safeETHTransfer(_msgSender(), sumWithdraw);
            }else {
                IERC20(pool.stTokenAddress).safeTransfer(_msgSender(), sumWithdraw);
            }
            // 2.2 质押的ECR20
        }

        emit Withdraw(pid, _msgSender(), sumWithdraw, block.number);
        return true;
    }

    function _safeETHTransfer(address to, uint256 amount) internal {
        payable(to).transfer(amount);
    }


    // 领取代币奖励
    function claim(uint256 pid) public whenNotPaused checkPid(pid) returns(bool) {
        Pool storage pool = _pool[pid];
        User storage user = _user[pid][_msgSender()];

        // 更新，然后按照最新的系数领取
        updatePool(pid);

        uint256 curPeedingToken = user.stAmount * pool.accRewardTokenPerST / (1 ether);
        uint256 peedingToken =  curPeedingToken - user.finishedRewardToken + user.pendingRewardToken;
        console.log("user.stAmount: ", user.stAmount);
        console.log("pool.accRewardTokenPerST: ", pool.accRewardTokenPerST);
        console.log("curPeedingToken: ", curPeedingToken);
        console.log("finishedRewardToken: ", user.finishedRewardToken);
        console.log("pendingRewardToken: ", user.pendingRewardToken);
        console.log("peedingToken: ", peedingToken);
        if(peedingToken > 0) {
            _safeRewardTokenTransfer(_msgSender(), peedingToken);
        }
        user.finishedRewardToken = curPeedingToken;

        emit Claim(pid, _msgSender(), peedingToken);
        return true;
    }

    function _safeRewardTokenTransfer(address to, uint256 amount) internal {
        require(amount < RewardToken.balanceOf(address(this)), "RewardToken balance not enough");
        RewardToken.transfer(to, amount);
    }

    /**
     * 添加质押池
     * @param stTokenAddress 质押token地址
     * @param poolWeight 池的权重
     * @param minDepositAmount 往池中质押的最小代币数
     * @param unstakeLockedBlocks token解锁需要历经的新区块数
     */
    function addPool(
        address stTokenAddress,
        uint256 poolWeight,
        uint256 minDepositAmount,
        uint256 unstakeLockedBlocks
    ) public returns (bool) {
        require(stTokenAddress != address(0), "invalid token address");
        require(unstakeLockedBlocks > 0, "unstakeLockedBlocks must gether than 0");
        require(block.number < _endBlock, "had stoped");
        uint256 lastRewardBlock = block.number > _startBlock ? block.number : _startBlock;
        _pool.push(
            Pool({
                stTokenAddress: stTokenAddress,
                poolWeight: poolWeight,
                minDepositAmount: minDepositAmount,
                unstakeLockedBlocks: unstakeLockedBlocks,
                lastRewardBlock: lastRewardBlock,
                accRewardTokenPerST: 0,
                stTokenAmount: 0
            })
        );
        _totalPoolsWeight += poolWeight;
        return true;
    }

    /**
     * 更新质押池的状态
     * 计算该池，自上次结算至目前，所有产生的代币奖励，应该分配给每个质押的份额（即每次需要结算奖励时，必须调用本函数获取最新的奖励因子）
     * @param pid 池id
     */
    function updatePool(uint pid) public {
        // require(pid < _pool.length - 1, "pid not exists");
        Pool storage pool = _pool[pid];
        
        // 已是最新状态
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        // 如果没有质押代币，更新为最新状态，然后结束
        uint256 stTokenAmount = pool.stTokenAmount;
        if (stTokenAmount == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        // 更新池中奖励
        // 新出区块产出的奖励token
        uint256 allRewardToken = blockRewardToken(pool.lastRewardBlock, block.number);
        console.log("allRewardToken: ", allRewardToken);
        // 根据权重，计算这个池的奖励。  精度因子，膨胀 1e18
        uint256 poolRewardToken = allRewardToken * (pool.poolWeight / _totalPoolsWeight) * (1 ether);
        console.log("poolRewardToken: ", poolRewardToken);

        // 平均到每个代币的奖励
        uint256 stTokenRewardToken = poolRewardToken / stTokenAmount;

        // 更新到池
        pool.accRewardTokenPerST += stTokenRewardToken;
        pool.lastRewardBlock = block.number;

        // 更新区块事件
        emit UpdatePool(pid, pool.lastRewardBlock, stTokenRewardToken);
    }

    function blockRewardToken(uint256 fromBlock, uint256 toBlock) internal view returns(uint256 rewardToken) {
        require(fromBlock <= toBlock, "invalid block range");
        // 与预设开始挖矿区块比较，取更高值
        fromBlock = fromBlock < _startBlock ? _startBlock : fromBlock;
        // 与预设结束挖矿区块比较，取更低值
        toBlock = toBlock > _endBlock ? _endBlock : toBlock;
        bool success;
        console.log("toBlock: ", toBlock);
        console.log("fromBlock: ", fromBlock);
        console.log("_rewardTokenPerBlock: ", _rewardTokenPerBlock);
        (success, rewardToken) = (toBlock - fromBlock).tryMul(_rewardTokenPerBlock);
        require(success, "block range mul _rewardTokenPerBlock overflow");
    }

    function _authorizeUpgrade(address) internal onlyRole(UPGRADE_ROLE) override {}


    ///////////////admin fucntion////////////////////

    // 更换奖励币
    function setRewardToken(IERC20 rewardToken) public onlyRole(ADMIN_ROLE) {
        RewardToken = rewardToken;
        emit SetRewardToken(rewardToken);
    }

    // 设置质押开关
    function setPauseDeposit(bool isPause) public onlyRole(ADMIN_ROLE) {
        pauseDeposit = isPause;
        emit SetPauseDeposit(isPause);
    }

    // 设置解除质押开关
    function setPauseUnstake(bool isPause) public onlyRole(ADMIN_ROLE) {
        pauseUnstake = isPause;
        emit SetPauseUnstake(isPause);
    }

    // 设置提现开关
    function setPauseWithdraw(bool isPause) public onlyRole(ADMIN_ROLE) {
        pauseWithdraw = isPause;
        emit SetPauseWithdraw(isPause);
    }

    // 设置提取奖励开关
    function setPauseClaim(bool isPause) public onlyRole(ADMIN_ROLE) {
        pauseWithdraw = isPause;
        emit SetPauseClaim(isPause);
    }

    // 设置奖励发放初始区块
    function setStartBlock(uint256 startBlock) public onlyRole(ADMIN_ROLE) {
        require(
            startBlock <= _endBlock,
            "start block must be smaller than end block"
        );

        _startBlock = startBlock;
        emit SetStartBlock(startBlock);
    }

    // 设置奖励发放结束区块
    function setEndBlock(uint256 endBlock) public onlyRole(ADMIN_ROLE) {
        require(
            _startBlock <= endBlock,
            "start block must be smaller than end block"
        );

        _endBlock = endBlock;
        emit SetEndBlock(endBlock);
    }

    // 设置每个区块出的励币个数
    function setRewardTokenBlock(
        uint256 rewardTokenBlock
    ) public onlyRole(ADMIN_ROLE) {
        require(rewardTokenBlock > 0, "invalid parameter");

        _rewardTokenPerBlock = rewardTokenBlock;
        emit SetRewardTokenPerBlock(rewardTokenBlock);
    }

    // 设置池权重
    function setPoolWeight(uint256 pid, uint256 poolWeight) public onlyRole(ADMIN_ROLE) {
        _totalPoolsWeight = _totalPoolsWeight - _pool[pid].poolWeight + poolWeight;
        _pool[pid].poolWeight = poolWeight;
        emit SetPoolWeight(pid, poolWeight, _totalPoolsWeight);
    }

    ///////////////////////////查询接口/////////////////////////////////
    // 查询池数量
    function poolLength() public view returns(uint256) {
        return _pool.length;
    }

    function startBlock() public view returns(uint256) {
        return _startBlock;
    }

    function endBlock() public view returns(uint256) {
        return _endBlock;
    }
}