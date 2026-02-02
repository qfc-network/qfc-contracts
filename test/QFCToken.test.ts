import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("QFCToken", function () {
  async function deployTokenFixture() {
    const [owner, addr1, addr2] = await ethers.getSigners();

    const QFCToken = await ethers.getContractFactory("QFCToken");
    const token = await QFCToken.deploy(
      "QFC Token",
      "QFC",
      ethers.parseEther("1000000"), // 1M cap
      ethers.parseEther("100000")   // 100K initial
    );

    return { token, owner, addr1, addr2 };
  }

  describe("Deployment", function () {
    it("Should set the right name and symbol", async function () {
      const { token } = await loadFixture(deployTokenFixture);

      expect(await token.name()).to.equal("QFC Token");
      expect(await token.symbol()).to.equal("QFC");
    });

    it("Should set the right owner", async function () {
      const { token, owner } = await loadFixture(deployTokenFixture);

      expect(await token.owner()).to.equal(owner.address);
    });

    it("Should assign initial supply to owner", async function () {
      const { token, owner } = await loadFixture(deployTokenFixture);

      expect(await token.balanceOf(owner.address)).to.equal(
        ethers.parseEther("100000")
      );
    });

    it("Should set the right cap", async function () {
      const { token } = await loadFixture(deployTokenFixture);

      expect(await token.cap()).to.equal(ethers.parseEther("1000000"));
    });
  });

  describe("Minting", function () {
    it("Should allow owner to mint", async function () {
      const { token, addr1 } = await loadFixture(deployTokenFixture);

      await token.mint(addr1.address, ethers.parseEther("1000"));
      expect(await token.balanceOf(addr1.address)).to.equal(
        ethers.parseEther("1000")
      );
    });

    it("Should not allow non-owner to mint", async function () {
      const { token, addr1 } = await loadFixture(deployTokenFixture);

      await expect(
        token.connect(addr1).mint(addr1.address, ethers.parseEther("1000"))
      ).to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount");
    });

    it("Should not mint over cap", async function () {
      const { token, addr1 } = await loadFixture(deployTokenFixture);

      await expect(
        token.mint(addr1.address, ethers.parseEther("1000000"))
      ).to.be.revertedWith("Cap exceeded");
    });
  });

  describe("Transfers", function () {
    it("Should transfer tokens between accounts", async function () {
      const { token, owner, addr1 } = await loadFixture(deployTokenFixture);

      await token.transfer(addr1.address, ethers.parseEther("100"));
      expect(await token.balanceOf(addr1.address)).to.equal(
        ethers.parseEther("100")
      );
    });

    it("Should fail if sender doesn't have enough tokens", async function () {
      const { token, addr1, addr2 } = await loadFixture(deployTokenFixture);

      await expect(
        token.connect(addr1).transfer(addr2.address, ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(token, "ERC20InsufficientBalance");
    });
  });

  describe("Batch Transfer", function () {
    it("Should batch transfer to multiple addresses", async function () {
      const { token, owner, addr1, addr2 } = await loadFixture(deployTokenFixture);

      await token.batchTransfer(
        [addr1.address, addr2.address],
        [ethers.parseEther("100"), ethers.parseEther("200")]
      );

      expect(await token.balanceOf(addr1.address)).to.equal(
        ethers.parseEther("100")
      );
      expect(await token.balanceOf(addr2.address)).to.equal(
        ethers.parseEther("200")
      );
    });
  });

  describe("Burning", function () {
    it("Should allow holders to burn their tokens", async function () {
      const { token, owner } = await loadFixture(deployTokenFixture);

      const initialBalance = await token.balanceOf(owner.address);
      await token.burn(ethers.parseEther("1000"));

      expect(await token.balanceOf(owner.address)).to.equal(
        initialBalance - ethers.parseEther("1000")
      );
    });
  });
});
