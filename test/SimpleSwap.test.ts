import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("SimpleSwap", function () {
  async function deploySwapFixture() {
    const [owner, user1, user2] = await ethers.getSigners();

    // Deploy tokens
    const QFCToken = await ethers.getContractFactory("QFCToken");

    const tokenA = await QFCToken.deploy(
      "Token A",
      "TKNA",
      ethers.parseEther("1000000000"),
      ethers.parseEther("1000000")
    );

    const tokenB = await QFCToken.deploy(
      "Token B",
      "TKNB",
      ethers.parseEther("1000000000"),
      ethers.parseEther("1000000")
    );

    // Deploy swap
    const SimpleSwap = await ethers.getContractFactory("SimpleSwap");
    const swap = await SimpleSwap.deploy(
      await tokenA.getAddress(),
      await tokenB.getAddress()
    );

    // Approve swap contract
    await tokenA.approve(await swap.getAddress(), ethers.MaxUint256);
    await tokenB.approve(await swap.getAddress(), ethers.MaxUint256);

    // Transfer tokens to users
    await tokenA.transfer(user1.address, ethers.parseEther("10000"));
    await tokenB.transfer(user1.address, ethers.parseEther("10000"));
    await tokenA.connect(user1).approve(await swap.getAddress(), ethers.MaxUint256);
    await tokenB.connect(user1).approve(await swap.getAddress(), ethers.MaxUint256);

    return { swap, tokenA, tokenB, owner, user1, user2 };
  }

  describe("Liquidity", function () {
    it("Should add initial liquidity", async function () {
      const { swap, tokenA, tokenB, owner } = await loadFixture(deploySwapFixture);

      const amount0 = ethers.parseEther("1000");
      const amount1 = ethers.parseEther("2000");

      await swap.addLiquidity(amount0, amount1);

      expect(await swap.reserve0()).to.equal(amount0);
      expect(await swap.reserve1()).to.equal(amount1);
      expect(await swap.liquidity(owner.address)).to.be.gt(0);
    });

    it("Should remove liquidity", async function () {
      const { swap, tokenA, tokenB, owner } = await loadFixture(deploySwapFixture);

      await swap.addLiquidity(
        ethers.parseEther("1000"),
        ethers.parseEther("2000")
      );

      const liquidity = await swap.liquidity(owner.address);
      const balanceA_before = await tokenA.balanceOf(owner.address);
      const balanceB_before = await tokenB.balanceOf(owner.address);

      await swap.removeLiquidity(liquidity);

      expect(await tokenA.balanceOf(owner.address)).to.be.gt(balanceA_before);
      expect(await tokenB.balanceOf(owner.address)).to.be.gt(balanceB_before);
    });
  });

  describe("Swapping", function () {
    it("Should swap token0 for token1", async function () {
      const { swap, tokenA, tokenB, owner, user1 } = await loadFixture(deploySwapFixture);

      // Add liquidity first
      await swap.addLiquidity(
        ethers.parseEther("10000"),
        ethers.parseEther("10000")
      );

      const amountIn = ethers.parseEther("100");
      const balanceBefore = await tokenB.balanceOf(user1.address);

      // Calculate expected output
      const expectedOut = await swap.getAmountOut(
        amountIn,
        await swap.reserve0(),
        await swap.reserve1()
      );

      await swap.connect(user1).swap0For1(amountIn, expectedOut);

      const balanceAfter = await tokenB.balanceOf(user1.address);
      expect(balanceAfter - balanceBefore).to.equal(expectedOut);
    });

    it("Should swap token1 for token0", async function () {
      const { swap, tokenA, tokenB, owner, user1 } = await loadFixture(deploySwapFixture);

      await swap.addLiquidity(
        ethers.parseEther("10000"),
        ethers.parseEther("10000")
      );

      const amountIn = ethers.parseEther("100");
      const balanceBefore = await tokenA.balanceOf(user1.address);

      const expectedOut = await swap.getAmountOut(
        amountIn,
        await swap.reserve1(),
        await swap.reserve0()
      );

      await swap.connect(user1).swap1For0(amountIn, expectedOut);

      const balanceAfter = await tokenA.balanceOf(user1.address);
      expect(balanceAfter - balanceBefore).to.equal(expectedOut);
    });

    it("Should fail with excessive slippage", async function () {
      const { swap, user1 } = await loadFixture(deploySwapFixture);

      await swap.addLiquidity(
        ethers.parseEther("10000"),
        ethers.parseEther("10000")
      );

      // Expect more output than possible
      await expect(
        swap.connect(user1).swap0For1(
          ethers.parseEther("100"),
          ethers.parseEther("200") // Impossible output
        )
      ).to.be.revertedWith("Slippage too high");
    });
  });

  describe("Price", function () {
    it("Should return correct prices", async function () {
      const { swap } = await loadFixture(deploySwapFixture);

      await swap.addLiquidity(
        ethers.parseEther("1000"),
        ethers.parseEther("2000")
      );

      // Price of token0 in terms of token1 should be ~2
      const price0 = await swap.getPrice0();
      expect(price0).to.equal(ethers.parseEther("2"));

      // Price of token1 in terms of token0 should be ~0.5
      const price1 = await swap.getPrice1();
      expect(price1).to.equal(ethers.parseEther("0.5"));
    });
  });
});
