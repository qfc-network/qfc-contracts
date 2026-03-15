import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("Privacy Pools Compliance", function () {
  async function deployFixture() {
    const [admin, curator, alice, bob, defiProtocol] = await ethers.getSigners();

    // Deploy AssociationSet
    const AssociationSet = await ethers.getContractFactory("AssociationSet");
    const assocSet = await AssociationSet.deploy(admin.address);

    const CURATOR_ROLE = await assocSet.CURATOR_ROLE();
    await assocSet.grantRole(CURATOR_ROLE, curator.address);

    // Deploy ComplianceVerifier
    const ComplianceVerifier = await ethers.getContractFactory("ComplianceVerifier");
    const verifier = await ComplianceVerifier.deploy(await assocSet.getAddress());

    // Create sample inclusion set (KYC'd addresses)
    const inclusionRoot = 12345678n; // Mock Poseidon root
    const tx = await assocSet.connect(curator).createSet(
      "KYC Verified Q1 2026",
      0, // Inclusion
      inclusionRoot,
      1000
    );
    const receipt = await tx.wait();
    const event = receipt!.logs.find(
      (log: any) => log.fragment?.name === "SetCreated"
    );
    const inclusionSetId = (event as any).args[0];

    // Create sample exclusion set (sanctioned addresses)
    const exclusionRoot = 87654321n;
    const tx2 = await assocSet.connect(curator).createSet(
      "OFAC Sanctions List",
      1, // Exclusion
      exclusionRoot,
      50
    );
    const receipt2 = await tx2.wait();
    const event2 = receipt2!.logs.find(
      (log: any) => log.fragment?.name === "SetCreated"
    );
    const exclusionSetId = (event2 as any).args[0];

    return { assocSet, verifier, admin, curator, alice, bob, defiProtocol,
             inclusionSetId, inclusionRoot, exclusionSetId, exclusionRoot };
  }

  describe("AssociationSet", function () {
    it("should create an inclusion set", async function () {
      const { assocSet, inclusionSetId, inclusionRoot } = await loadFixture(deployFixture);

      const set = await assocSet.getSet(inclusionSetId);
      expect(set.name).to.equal("KYC Verified Q1 2026");
      expect(set.setType).to.equal(0); // Inclusion
      expect(set.root).to.equal(inclusionRoot);
      expect(set.memberCount).to.equal(1000);
      expect(set.active).to.be.true;
    });

    it("should create an exclusion set", async function () {
      const { assocSet, exclusionSetId } = await loadFixture(deployFixture);

      const set = await assocSet.getSet(exclusionSetId);
      expect(set.name).to.equal("OFAC Sanctions List");
      expect(set.setType).to.equal(1); // Exclusion
    });

    it("should update set root", async function () {
      const { assocSet, curator, inclusionSetId } = await loadFixture(deployFixture);

      const newRoot = 99999999n;
      await expect(assocSet.connect(curator).updateSet(inclusionSetId, newRoot, 1200))
        .to.emit(assocSet, "SetUpdated")
        .withArgs(inclusionSetId, newRoot, 1200);

      expect(await assocSet.getSetRoot(inclusionSetId)).to.equal(newRoot);
    });

    it("should deactivate and reactivate a set", async function () {
      const { assocSet, admin, inclusionSetId } = await loadFixture(deployFixture);

      await assocSet.connect(admin).deactivateSet(inclusionSetId);
      await expect(assocSet.getSetRoot(inclusionSetId))
        .to.be.revertedWithCustomError(assocSet, "SetNotActive");

      await assocSet.connect(admin).activateSet(inclusionSetId);
      expect(await assocSet.getSetRoot(inclusionSetId)).to.not.equal(0);
    });

    it("should return active inclusion sets", async function () {
      const { assocSet } = await loadFixture(deployFixture);
      const sets = await assocSet.getActiveInclusionSets();
      expect(sets.length).to.equal(1);
    });

    it("should return active exclusion sets", async function () {
      const { assocSet } = await loadFixture(deployFixture);
      const sets = await assocSet.getActiveExclusionSets();
      expect(sets.length).to.equal(1);
    });

    it("should reject zero root", async function () {
      const { assocSet, curator } = await loadFixture(deployFixture);
      await expect(assocSet.connect(curator).createSet("Bad Set", 0, 0, 10))
        .to.be.revertedWithCustomError(assocSet, "InvalidRoot");
    });

    it("should reject unauthorized curator", async function () {
      const { assocSet, alice } = await loadFixture(deployFixture);
      await expect(assocSet.connect(alice).createSet("Unauthorized", 0, 123n, 10))
        .to.be.reverted;
    });

    it("should return set count", async function () {
      const { assocSet } = await loadFixture(deployFixture);
      expect(await assocSet.setCount()).to.equal(2);
    });
  });

  describe("ComplianceVerifier", function () {
    it("should prove Basic compliance (inclusion only)", async function () {
      const { verifier, inclusionSetId, inclusionRoot, alice } = await loadFixture(deployFixture);

      const nullifierHash = 111222333n;

      await expect(verifier.connect(alice).proveCompliance(
        nullifierHash,
        [inclusionSetId],    // inclusion sets
        [inclusionRoot],     // roots must match on-chain
        [],                  // no exclusion sets
        []
      )).to.emit(verifier, "ComplianceProved");

      // Check compliance level
      expect(await verifier.getComplianceLevel(nullifierHash)).to.equal(1); // Basic
    });

    it("should prove Full compliance (inclusion + exclusion)", async function () {
      const { verifier, inclusionSetId, inclusionRoot, exclusionSetId, exclusionRoot, alice } =
        await loadFixture(deployFixture);

      const nullifierHash = 444555666n;

      await verifier.connect(alice).proveCompliance(
        nullifierHash,
        [inclusionSetId],
        [inclusionRoot],
        [exclusionSetId],
        [exclusionRoot]
      );

      expect(await verifier.getComplianceLevel(nullifierHash)).to.equal(2); // Full
    });

    it("should reject mismatched root", async function () {
      const { verifier, inclusionSetId, alice } = await loadFixture(deployFixture);

      await expect(verifier.connect(alice).proveCompliance(
        777888999n,
        [inclusionSetId],
        [99999n], // wrong root
        [],
        []
      )).to.be.revertedWithCustomError(verifier, "InvalidProof");
    });

    it("should reject duplicate compliance proof", async function () {
      const { verifier, inclusionSetId, inclusionRoot, alice } = await loadFixture(deployFixture);

      const nullifierHash = 123456n;
      await verifier.connect(alice).proveCompliance(
        nullifierHash, [inclusionSetId], [inclusionRoot], [], []
      );

      await expect(verifier.connect(alice).proveCompliance(
        nullifierHash, [inclusionSetId], [inclusionRoot], [], []
      )).to.be.revertedWithCustomError(verifier, "AlreadyVerified");
    });

    it("should reject inactive set", async function () {
      const { assocSet, verifier, admin, inclusionSetId, inclusionRoot, alice } =
        await loadFixture(deployFixture);

      await assocSet.connect(admin).deactivateSet(inclusionSetId);

      await expect(verifier.connect(alice).proveCompliance(
        999n, [inclusionSetId], [inclusionRoot], [], []
      )).to.be.revertedWithCustomError(verifier, "SetNotActive");
    });

    it("should reject wrong set type", async function () {
      const { verifier, exclusionSetId, exclusionRoot, alice } =
        await loadFixture(deployFixture);

      // Try to use exclusion set as inclusion
      await expect(verifier.connect(alice).proveCompliance(
        888n, [exclusionSetId], [exclusionRoot], [], []
      )).to.be.revertedWithCustomError(verifier, "InvalidAssociationSet");
    });
  });

  describe("DeFi Integration (meetsComplianceLevel)", function () {
    it("should check if withdrawal meets minimum level", async function () {
      const { verifier, inclusionSetId, inclusionRoot, alice } =
        await loadFixture(deployFixture);

      const nullifierHash = 42n;
      await verifier.connect(alice).proveCompliance(
        nullifierHash, [inclusionSetId], [inclusionRoot], [], []
      );

      // Basic (1) meets None (0)
      expect(await verifier.meetsComplianceLevel(nullifierHash, 0)).to.be.true;
      // Basic (1) meets Basic (1)
      expect(await verifier.meetsComplianceLevel(nullifierHash, 1)).to.be.true;
      // Basic (1) does NOT meet Full (2)
      expect(await verifier.meetsComplianceLevel(nullifierHash, 2)).to.be.false;
    });

    it("should return None for unverified withdrawal", async function () {
      const { verifier } = await loadFixture(deployFixture);
      expect(await verifier.getComplianceLevel(12345n)).to.equal(0); // None
    });

    it("should return full compliance record", async function () {
      const { verifier, inclusionSetId, inclusionRoot, exclusionSetId, exclusionRoot, alice } =
        await loadFixture(deployFixture);

      const nullifierHash = 777n;
      await verifier.connect(alice).proveCompliance(
        nullifierHash,
        [inclusionSetId], [inclusionRoot],
        [exclusionSetId], [exclusionRoot]
      );

      const record = await verifier.getComplianceRecord(nullifierHash);
      expect(record.level).to.equal(2); // Full
      expect(record.inclusionSets.length).to.equal(1);
      expect(record.exclusionSets.length).to.equal(1);
      expect(record.verifiedAt).to.be.gt(0);
    });
  });
});
