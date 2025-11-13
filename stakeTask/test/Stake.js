const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MetaNodeStake", function () {
    let MetaNodeStake;
    let RewardToken;
    let StakingToken;
    let metaNodeStake;
    let rewardToken;
    let stakingToken;
    let owner;
    let user1;
    let user2;
    let admin;

    // const REWARD_PER_BLOCK = 1;
    const REWARD_PER_BLOCK = ethers.parseEther("1");
    // const MIN_DEPOSIT = 0.1;
    const MIN_DEPOSIT = ethers.parseEther("0.1");

    beforeEach(async function () {
        [owner, user1, user2, admin] = await ethers.getSigners();

        // 部署奖励代币
        const ERC20 = await ethers.getContractFactory("ERC20Mock");
        rewardToken = await ERC20.deploy("Reward Token", "RWT", ethers.parseEther("1000000"));

        // 部署质押代币
        stakingToken = await ERC20.deploy("Staking Token", "STK", ethers.parseEther("1000000"));

        // 部署质押合约
        MetaNodeStake = await ethers.getContractFactory("MetaNodeStake");
        metaNodeStake = await MetaNodeStake.deploy();

        // 获取当前区块
        const currentBlock = await ethers.provider.getBlockNumber();
        const START_BLOCK = currentBlock + 10;
        const END_BLOCK = START_BLOCK + 900;

        // 初始化合约
        await metaNodeStake.initialize(
            await rewardToken.getAddress(),
            START_BLOCK,
            END_BLOCK,
            REWARD_PER_BLOCK
        );

        // 给用户分配代币
        await stakingToken.transfer(user1.address, ethers.parseEther("1000"));
        await stakingToken.transfer(user2.address, ethers.parseEther("1000"));
        await rewardToken.transfer(await metaNodeStake.getAddress(), ethers.parseEther("100000"));

        // 添加ERC20质押池
        await metaNodeStake.addPool(
            await stakingToken.getAddress(),
            200, // weight
            MIN_DEPOSIT,
            10   // unstakeLockedBlocks
        );
    });

    describe("初始化测试", function () {
        it("应该正确初始化合约", async function () {
            expect(await metaNodeStake.RewardToken()).to.equal(await rewardToken.getAddress());
            expect(await metaNodeStake.poolLength()).to.equal(2); // ETH池 + ERC20池
        });

        it("应该设置正确的角色", async function () {
            expect(await metaNodeStake.hasRole(await metaNodeStake.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
            expect(await metaNodeStake.hasRole(await metaNodeStake.ADMIN_ROLE(), owner.address)).to.be.true;
        });
    });

    describe("ETH质押测试", function () {
        it("应该允许用户质押ETH", async function () {
            const depositAmount = ethers.parseEther("1");

            await expect(
                metaNodeStake.connect(user1).depositETH({ value: depositAmount })
            ).to.emit(metaNodeStake, "Deposit").withArgs(0, user1.address, depositAmount);

            // 检查合约余额
            expect(await ethers.provider.getBalance(await metaNodeStake.getAddress())).to.equal(depositAmount);
        });

        it("应该拒绝低于最小质押金额的ETH存款", async function () {
            const smallAmount = ethers.parseEther("0.00001");

            await expect(
                metaNodeStake.connect(user1).depositETH({ value: smallAmount })
            ).to.be.revertedWith("AmountTooSmall");
        });
    });

    describe("ERC20质押测试", function () {
        beforeEach(async function () {
            // 用户授权质押合约使用代币
            await stakingToken.connect(user1).approve(await metaNodeStake.getAddress(), ethers.parseEther("100"));
        });

        it("应该允许用户质押ERC20代币", async function () {
            const depositAmount = ethers.parseEther("10");

            await expect(
                metaNodeStake.connect(user1).deposit(1, depositAmount)
            ).to.emit(metaNodeStake, "Deposit").withArgs(1, user1.address, depositAmount);

            // 检查合约中的代币余额
            expect(await stakingToken.balanceOf(await metaNodeStake.getAddress())).to.equal(depositAmount);
        });

        it("应该拒绝无效的池ID", async function () {
            await expect(
                metaNodeStake.connect(user1).deposit(5, ethers.parseEther("1"))
            ).to.be.revertedWith("invalid pid");
        });
    });

    describe("奖励计算测试", function () {
        beforeEach(async function () {
            // 用户质押代币
            await stakingToken.connect(user1).approve(await metaNodeStake.getAddress(), ethers.parseEther("100"));
            await metaNodeStake.connect(user1).deposit(1, ethers.parseEther("10"));
        });

        it("应该正确计算奖励", async function () {
            // 推进区块以产生奖励
            // await ethers.provider.send("evm_mine", [START_BLOCK + 10]);
            const blocksToAdvance = 10;
            for (let i = 0; i < blocksToAdvance; i++) {
                await ethers.provider.send("evm_mine");
            }

            // 更新池并领取奖励
            await metaNodeStake.connect(user1).updatePool(1);
            await metaNodeStake.connect(user1).claim(1);

            // 应该有一些奖励被领取
            const userBalance = await rewardToken.balanceOf(user1.address);
            expect(userBalance).to.be.gt(0);
        });

        it("应该在解除质押时累积待领取奖励", async function () {
            // 推进区块
            // await ethers.provider.send("evm_mine", [START_BLOCK + 5]);
            const blocksToAdvance = 10;
            for (let i = 0; i < blocksToAdvance; i++) {
                await ethers.provider.send("evm_mine");
            }

            // 部分解除质押
            await metaNodeStake.connect(user1).unstake(1, ethers.parseEther("5"));

            // 检查是否有待领取奖励
            // 注意：这里需要添加一个视图函数来检查用户状态，或者通过事件验证
        });
    });

    describe("解除质押和提现测试", function () {
        beforeEach(async function () {
            await stakingToken.connect(user1).approve(await metaNodeStake.getAddress(), ethers.parseEther("100"));
            await metaNodeStake.connect(user1).deposit(1, ethers.parseEther("10"));
        });

        it("应该允许用户解除质押", async function () {
            const unstakeAmount = ethers.parseEther("5");

            await expect(
                metaNodeStake.connect(user1).unstake(1, unstakeAmount)
            ).to.emit(metaNodeStake, "Unstake").withArgs(1, user1.address, unstakeAmount);
        });

        it("应该拒绝超过质押数量的解除质押", async function () {
            await expect(
                metaNodeStake.connect(user1).unstake(1, ethers.parseEther("20"))
            ).to.be.revertedWith("your st amount less than amount");
        });

        it("应该允许在锁定期后提现", async function () {
            const unstakeAmount = ethers.parseEther("5");

            // 解除质押
            await metaNodeStake.connect(user1).unstake(1, unstakeAmount);

            // 推进区块超过锁定期
            for (let i = 0; i < 15; i++) {
                await ethers.provider.send("evm_mine");
            }

            // 提现
            await expect(
                metaNodeStake.connect(user1).withdraw(1)
            ).to.emit(metaNodeStake, "Withdraw");

            // 检查用户余额增加
            const userBalance = await stakingToken.balanceOf(user1.address);
            console.log("userBalance: ", userBalance);
            expect(userBalance).to.be.eq(ethers.parseEther("995")); // 初始1000 - 质押10 + 提现5
        });
    });

    describe("管理员功能测试", function () {
        let ERC20;
        beforeEach(async function () {
            // 在beforeEach中初始化ERC20
            ERC20 = await ethers.getContractFactory("ERC20Mock");
        });

        it("应该允许管理员更新奖励代币", async function () {
            const newRewardToken = await ERC20.deploy("New Reward", "NEW", ethers.parseEther("1000000"));

            await expect(
                metaNodeStake.setRewardToken(await newRewardToken.getAddress())
            ).to.emit(metaNodeStake, "SetRewardToken");
        });

        it("应该允许管理员更新池权重", async function () {
            const newWeight = 300;

            await expect(
                metaNodeStake.setPoolWeight(1, newWeight)
            ).to.emit(metaNodeStake, "SetPoolWeight").withArgs(1, newWeight, 300); // 总权重100+300=400
        });

        it("应该允许管理员暂停功能", async function () {
            await metaNodeStake.setPauseDeposit(true);
            expect(await metaNodeStake.pauseDeposit()).to.be.true;

            await metaNodeStake.setPauseUnstake(true);
            expect(await metaNodeStake.pauseUnstake()).to.be.true;

            await metaNodeStake.setPauseWithdraw(true);
            expect(await metaNodeStake.pauseWithdraw()).to.be.true;
        });

        it("应该拒绝非管理员调用管理功能", async function () {
            await expect(
                metaNodeStake.connect(user1).setPauseDeposit(true)
            ).to.be.reverted;
        });
    });

    describe("边缘情况测试", function () {
        it("应该在无质押时代币时正常处理", async function () {
            // 更新空池应该不会报错
            await expect(metaNodeStake.updatePool(1)).not.to.be.reverted;
        });

        it("应该在奖励期间外正确处理", async function () {
            // 推进到奖励期结束后
            // await ethers.provider.send("evm_mine", [END_BLOCK + 100]);

            // 获取合约中的结束区块
            const endBlock = await metaNodeStake.endBlock();
            // 首先获取当前区块号
            const currentBlock = await ethers.provider.getBlockNumber();

            // 如果当前区块已经超过结束区块，直接测试
            if (currentBlock <= endBlock) {
                // 推进到结束区块之后
                const blocksToMine = endBlock - BigInt(currentBlock) + 100n;
                for (let i = 0; i < blocksToMine; i++) {
                    await ethers.provider.send("evm_increaseTime", [15]); // 假设15秒一个区块
                    await ethers.provider.send("evm_mine");
                }
            }

            // 质押应该仍然可以工作，但不会产生新奖励
            await stakingToken.connect(user1).approve(await metaNodeStake.getAddress(), ethers.parseEther("10"));
            await metaNodeStake.connect(user1).deposit(1, ethers.parseEther("1"));
        });

        it("应该处理多个用户的并发操作", async function () {
            // 设置多个用户
            await stakingToken.connect(user1).approve(await metaNodeStake.getAddress(), ethers.parseEther("50"));
            await stakingToken.connect(user2).approve(await metaNodeStake.getAddress(), ethers.parseEther("50"));

            // 并发质押
            await Promise.all([
                metaNodeStake.connect(user1).deposit(1, ethers.parseEther("10")),
                metaNodeStake.connect(user2).deposit(1, ethers.parseEther("20"))
            ]);

            // 推进区块
            // await ethers.provider.send("evm_mine", [START_BLOCK + 10]);
            for (let i = 0; i < 15; i++) {
                await ethers.provider.send("evm_mine");
            }

            // 并发领取奖励
            await Promise.all([
                metaNodeStake.connect(user1).claim(1),
                metaNodeStake.connect(user2).claim(1)
            ]);

            // 两个用户都应该收到奖励
            const balance1 = await rewardToken.balanceOf(user1.address);
            const balance2 = await rewardToken.balanceOf(user2.address);
            expect(balance1).to.be.gt(0);
            expect(balance2).to.be.gt(0);
        });
    });
});