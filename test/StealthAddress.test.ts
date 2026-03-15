import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("StealthAddress (EIP-5564)", function () {
  async function deployFixture() {
    const [owner, alice, bob, carol] = await ethers.getSigners();

    // Deploy mock qUSD
    const MockToken = await ethers.getContractFactory("QFCToken");
    const qusd = await MockToken.deploy("qUSD Stablecoin", "qUSD", ethers.parseEther("1000000000"), ethers.parseEther("10000000"));

    // Deploy StealthAddress
    const StealthAddress = await ethers.getContractFactory("StealthAddress");
    const stealth = await StealthAddress.deploy();

    await qusd.transfer(alice.address, ethers.parseEther("100000"));

    return { qusd, stealth, owner, alice, bob, carol };
  }

  // Mock key generation
  function generateKeys() {
    const spendingKey = ethers.randomBytes(33); // compressed pubkey
    const viewingKey = ethers.randomBytes(33);
    return { spendingKey, viewingKey };
  }

  describe("Registry", function () {
    it("should register a stealth meta-address", async function () {
      const { stealth, bob } = await loadFixture(deployFixture);
      const { spendingKey, viewingKey } = generateKeys();

      await expect(stealth.connect(bob).registerMetaAddress(spendingKey, viewingKey))
        .to.emit(stealth, "StealthMetaAddressRegistered")
        .withArgs(bob.address, ethers.hexlify(spendingKey), ethers.hexlify(viewingKey));

      const [spending, viewing] = await stealth.getMetaAddress(bob.address);
      expect(spending).to.equal(ethers.hexlify(spendingKey));
      expect(viewing).to.equal(ethers.hexlify(viewingKey));
    });

    it("should reject duplicate registration", async function () {
      const { stealth, bob } = await loadFixture(deployFixture);
      const keys = generateKeys();

      await stealth.connect(bob).registerMetaAddress(keys.spendingKey, keys.viewingKey);

      await expect(stealth.connect(bob).registerMetaAddress(keys.spendingKey, keys.viewingKey))
        .to.be.revertedWithCustomError(stealth, "AlreadyRegistered");
    });

    it("should reject empty pubkeys", async function () {
      const { stealth, bob } = await loadFixture(deployFixture);

      await expect(stealth.connect(bob).registerMetaAddress("0x", ethers.randomBytes(33)))
        .to.be.revertedWithCustomError(stealth, "InvalidPubKey");
    });

    it("should update meta-address", async function () {
      const { stealth, bob } = await loadFixture(deployFixture);
      const keys1 = generateKeys();
      const keys2 = generateKeys();

      await stealth.connect(bob).registerMetaAddress(keys1.spendingKey, keys1.viewingKey);
      await stealth.connect(bob).updateMetaAddress(keys2.spendingKey, keys2.viewingKey);

      const [spending] = await stealth.getMetaAddress(bob.address);
      expect(spending).to.equal(ethers.hexlify(keys2.spendingKey));
    });

    it("should reject update without registration", async function () {
      const { stealth, carol } = await loadFixture(deployFixture);
      const keys = generateKeys();

      await expect(stealth.connect(carol).updateMetaAddress(keys.spendingKey, keys.viewingKey))
        .to.be.revertedWithCustomError(stealth, "NotRegistered");
    });

    it("should reject getMetaAddress for unregistered user", async function () {
      const { stealth, carol } = await loadFixture(deployFixture);
      await expect(stealth.getMetaAddress(carol.address))
        .to.be.revertedWithCustomError(stealth, "NotRegistered");
    });
  });

  describe("Stealth Transfer", function () {
    it("should send qUSD to a stealth address", async function () {
      const { stealth, qusd, alice } = await loadFixture(deployFixture);

      const stealthAddr = ethers.Wallet.createRandom().address;
      const ephemeralPubKey = ethers.randomBytes(33);
      const viewTag = ethers.keccak256(ethers.randomBytes(32));
      const amount = ethers.parseEther("1000");

      await qusd.connect(alice).approve(await stealth.getAddress(), amount);

      await expect(stealth.connect(alice).sendStealth(
        await qusd.getAddress(),
        stealthAddr,
        amount,
        ephemeralPubKey,
        viewTag
      )).to.emit(stealth, "StealthTransfer")
        .withArgs(await qusd.getAddress(), stealthAddr, ethers.hexlify(ephemeralPubKey), viewTag, amount);

      // Tokens should be at stealth address
      expect(await qusd.balanceOf(stealthAddr)).to.equal(amount);
    });

    it("should reject zero amount", async function () {
      const { stealth, qusd, alice } = await loadFixture(deployFixture);

      await expect(stealth.connect(alice).sendStealth(
        await qusd.getAddress(),
        ethers.Wallet.createRandom().address,
        0,
        ethers.randomBytes(33),
        ethers.ZeroHash
      )).to.be.revertedWithCustomError(stealth, "ZeroAmount");
    });

    it("should record announcement", async function () {
      const { stealth, qusd, alice } = await loadFixture(deployFixture);

      const stealthAddr = ethers.Wallet.createRandom().address;
      const amount = ethers.parseEther("500");

      await qusd.connect(alice).approve(await stealth.getAddress(), amount);
      await stealth.connect(alice).sendStealth(
        await qusd.getAddress(), stealthAddr, amount,
        ethers.randomBytes(33), ethers.ZeroHash
      );

      expect(await stealth.announcementCount()).to.equal(1);
    });
  });

  describe("Announcement Scanning", function () {
    it("should return announcements in range", async function () {
      const { stealth, qusd, alice } = await loadFixture(deployFixture);

      await qusd.connect(alice).approve(await stealth.getAddress(), ethers.parseEther("3000"));

      for (let i = 0; i < 3; i++) {
        await stealth.connect(alice).sendStealth(
          await qusd.getAddress(),
          ethers.Wallet.createRandom().address,
          ethers.parseEther("1000"),
          ethers.randomBytes(33),
          ethers.keccak256(ethers.toUtf8Bytes(`tag${i}`))
        );
      }

      const results = await stealth.getAnnouncements(0, 10);
      expect(results.length).to.equal(3);

      const partial = await stealth.getAnnouncements(1, 1);
      expect(partial.length).to.equal(1);
    });

    it("should filter by viewTag", async function () {
      const { stealth, qusd, alice } = await loadFixture(deployFixture);

      const targetTag = ethers.keccak256(ethers.toUtf8Bytes("my-tag"));
      const otherTag = ethers.keccak256(ethers.toUtf8Bytes("other-tag"));

      await qusd.connect(alice).approve(await stealth.getAddress(), ethers.parseEther("3000"));

      await stealth.connect(alice).sendStealth(
        await qusd.getAddress(), ethers.Wallet.createRandom().address,
        ethers.parseEther("1000"), ethers.randomBytes(33), otherTag
      );
      await stealth.connect(alice).sendStealth(
        await qusd.getAddress(), ethers.Wallet.createRandom().address,
        ethers.parseEther("1000"), ethers.randomBytes(33), targetTag
      );
      await stealth.connect(alice).sendStealth(
        await qusd.getAddress(), ethers.Wallet.createRandom().address,
        ethers.parseEther("1000"), ethers.randomBytes(33), otherTag
      );

      const matches = await stealth.scanByViewTag(targetTag, 0, 10);
      expect(matches.length).to.equal(1);
      expect(matches[0].viewTag).to.equal(targetTag);
    });

    it("should return empty for out-of-range query", async function () {
      const { stealth } = await loadFixture(deployFixture);
      const results = await stealth.getAnnouncements(100, 10);
      expect(results.length).to.equal(0);
    });
  });
});
