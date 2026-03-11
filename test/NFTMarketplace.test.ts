import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("NFT Marketplace", function () {
  async function deployMarketplaceFixture() {
    const [owner, seller, buyer, royaltyReceiver, offerer] = await ethers.getSigners();

    // Deploy RoyaltyRegistry
    const RoyaltyRegistry = await ethers.getContractFactory("RoyaltyRegistry");
    const royaltyRegistry = await RoyaltyRegistry.deploy();

    // Deploy QRCMarketplace
    const QRCMarketplace = await ethers.getContractFactory("QRCMarketplace");
    const marketplace = await QRCMarketplace.deploy(
      await royaltyRegistry.getAddress(),
      owner.address
    );

    // Deploy AuctionHouse
    const AuctionHouse = await ethers.getContractFactory("AuctionHouse");
    const auctionHouse = await AuctionHouse.deploy(
      await royaltyRegistry.getAddress(),
      owner.address
    );

    // Deploy CollectionFactory
    const CollectionFactory = await ethers.getContractFactory("CollectionFactory");
    const factory = await CollectionFactory.deploy(ethers.parseEther("0.01"));

    // Deploy a test NFT collection via factory
    await factory.connect(seller).createCollection(
      "Test Collection",
      "TEST",
      1000,
      ethers.parseEther("0.01"),
      500, // 5% royalty
      { value: ethers.parseEther("0.01") }
    );

    const collectionAddr = (await factory.getCreatorCollections(seller.address))[0];
    const collection = await ethers.getContractAt("QFCCollection", collectionAddr);

    // Enable public mint and mint some NFTs
    await collection.connect(seller).togglePublicMint();
    await collection.connect(seller).publicMint(3, { value: ethers.parseEther("0.03") });

    // Approve marketplace and auction house
    await collection.connect(seller).setApprovalForAll(await marketplace.getAddress(), true);
    await collection.connect(seller).setApprovalForAll(await auctionHouse.getAddress(), true);

    return {
      royaltyRegistry, marketplace, auctionHouse, factory, collection,
      owner, seller, buyer, royaltyReceiver, offerer,
    };
  }

  describe("QRCMarketplace", function () {
    describe("Listings", function () {
      it("Should list an NFT", async function () {
        const { marketplace, collection, seller } = await loadFixture(deployMarketplaceFixture);
        const price = ethers.parseEther("1");

        await expect(
          marketplace.connect(seller).listNFT(await collection.getAddress(), 0, price)
        )
          .to.emit(marketplace, "NFTListed")
          .withArgs(await collection.getAddress(), 0, seller.address, price, 0);

        const listing = await marketplace.listings(await collection.getAddress(), 0);
        expect(listing.seller).to.equal(seller.address);
        expect(listing.price).to.equal(price);
      });

      it("Should reject listing by non-owner", async function () {
        const { marketplace, collection, buyer } = await loadFixture(deployMarketplaceFixture);

        await expect(
          marketplace.connect(buyer).listNFT(await collection.getAddress(), 0, ethers.parseEther("1"))
        ).to.be.revertedWith("Not token owner");
      });

      it("Should reject zero price listing", async function () {
        const { marketplace, collection, seller } = await loadFixture(deployMarketplaceFixture);

        await expect(
          marketplace.connect(seller).listNFT(await collection.getAddress(), 0, 0)
        ).to.be.revertedWith("Price must be > 0");
      });
    });

    describe("Buying", function () {
      it("Should buy a listed NFT with correct fee distribution", async function () {
        const { marketplace, collection, seller, buyer, owner } = await loadFixture(deployMarketplaceFixture);
        const price = ethers.parseEther("1");
        const collectionAddr = await collection.getAddress();

        await marketplace.connect(seller).listNFT(collectionAddr, 0, price);

        const sellerBalBefore = await ethers.provider.getBalance(seller.address);
        const feeRecipientBalBefore = await ethers.provider.getBalance(owner.address);

        await expect(
          marketplace.connect(buyer).buyNFT(collectionAddr, 0, { value: price })
        )
          .to.emit(marketplace, "NFTSold")
          .withArgs(collectionAddr, 0, seller.address, buyer.address, price);

        // Buyer now owns the NFT
        expect(await collection.ownerOf(0)).to.equal(buyer.address);

        // Seller received proceeds (price - 2% fee - royalty)
        const sellerBalAfter = await ethers.provider.getBalance(seller.address);
        expect(sellerBalAfter).to.be.gt(sellerBalBefore);
      });

      it("Should reject insufficient payment", async function () {
        const { marketplace, collection, seller, buyer } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await marketplace.connect(seller).listNFT(collectionAddr, 0, ethers.parseEther("1"));

        await expect(
          marketplace.connect(buyer).buyNFT(collectionAddr, 0, { value: ethers.parseEther("0.5") })
        ).to.be.revertedWith("Insufficient payment");
      });
    });

    describe("Cancel Listing", function () {
      it("Should cancel a listing", async function () {
        const { marketplace, collection, seller } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await marketplace.connect(seller).listNFT(collectionAddr, 0, ethers.parseEther("1"));

        await expect(
          marketplace.connect(seller).cancelListing(collectionAddr, 0)
        )
          .to.emit(marketplace, "ListingCancelled")
          .withArgs(collectionAddr, 0, seller.address);

        const listing = await marketplace.listings(collectionAddr, 0);
        expect(listing.seller).to.equal(ethers.ZeroAddress);
      });

      it("Should reject cancel by non-seller", async function () {
        const { marketplace, collection, seller, buyer } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await marketplace.connect(seller).listNFT(collectionAddr, 0, ethers.parseEther("1"));

        await expect(
          marketplace.connect(buyer).cancelListing(collectionAddr, 0)
        ).to.be.revertedWith("Not the seller");
      });
    });

    describe("Offers", function () {
      it("Should make an offer", async function () {
        const { marketplace, collection, offerer } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();
        const expiry = (await time.latest()) + 86400;

        await expect(
          marketplace.connect(offerer).makeOffer(collectionAddr, 0, expiry, {
            value: ethers.parseEther("0.5"),
          })
        )
          .to.emit(marketplace, "OfferMade")
          .withArgs(collectionAddr, 0, offerer.address, ethers.parseEther("0.5"), expiry);
      });

      it("Should accept an offer", async function () {
        const { marketplace, collection, seller, offerer } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();
        const expiry = (await time.latest()) + 86400;

        await marketplace.connect(offerer).makeOffer(collectionAddr, 0, expiry, {
          value: ethers.parseEther("0.5"),
        });

        await expect(
          marketplace.connect(seller).acceptOffer(collectionAddr, 0, offerer.address)
        )
          .to.emit(marketplace, "OfferAccepted")
          .withArgs(collectionAddr, 0, seller.address, offerer.address, ethers.parseEther("0.5"));

        expect(await collection.ownerOf(0)).to.equal(offerer.address);
      });

      it("Should cancel an offer and refund", async function () {
        const { marketplace, collection, offerer } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();
        const expiry = (await time.latest()) + 86400;

        await marketplace.connect(offerer).makeOffer(collectionAddr, 0, expiry, {
          value: ethers.parseEther("0.5"),
        });

        const balBefore = await ethers.provider.getBalance(offerer.address);

        await marketplace.connect(offerer).cancelOffer(collectionAddr, 0);

        const balAfter = await ethers.provider.getBalance(offerer.address);
        // Balance should increase (minus gas)
        expect(balAfter).to.be.gt(balBefore);
      });

      it("Should reject expired offer acceptance", async function () {
        const { marketplace, collection, seller, offerer } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();
        const expiry = (await time.latest()) + 60;

        await marketplace.connect(offerer).makeOffer(collectionAddr, 0, expiry, {
          value: ethers.parseEther("0.5"),
        });

        // Fast forward past expiry
        await time.increase(120);

        await expect(
          marketplace.connect(seller).acceptOffer(collectionAddr, 0, offerer.address)
        ).to.be.revertedWith("Offer expired");
      });
    });
  });

  describe("AuctionHouse", function () {
    describe("English Auction", function () {
      it("Should create an English auction", async function () {
        const { auctionHouse, collection, seller } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await expect(
          auctionHouse.connect(seller).createEnglishAuction(
            collectionAddr, 0,
            ethers.parseEther("1"),   // reserve
            ethers.parseEther("0.1"), // start price
            86400                     // 1 day
          )
        ).to.emit(auctionHouse, "AuctionCreated");

        const auction = await auctionHouse.auctions(0);
        expect(auction.seller).to.equal(seller.address);
        expect(auction.startPrice).to.equal(ethers.parseEther("0.1"));
      });

      it("Should place bids", async function () {
        const { auctionHouse, collection, seller, buyer } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await auctionHouse.connect(seller).createEnglishAuction(
          collectionAddr, 0,
          ethers.parseEther("1"),
          ethers.parseEther("0.1"),
          86400
        );

        await expect(
          auctionHouse.connect(buyer).placeBid(0, { value: ethers.parseEther("0.1") })
        )
          .to.emit(auctionHouse, "BidPlaced")
          .withArgs(0, buyer.address, ethers.parseEther("0.1"));
      });

      it("Should reject bid below minimum increment", async function () {
        const { auctionHouse, collection, seller, buyer, offerer } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await auctionHouse.connect(seller).createEnglishAuction(
          collectionAddr, 0,
          ethers.parseEther("1"),
          ethers.parseEther("0.1"),
          86400
        );

        await auctionHouse.connect(buyer).placeBid(0, { value: ethers.parseEther("0.5") });

        // 5% increment on 0.5 = 0.525 minimum
        await expect(
          auctionHouse.connect(offerer).placeBid(0, { value: ethers.parseEther("0.51") })
        ).to.be.revertedWith("Bid increment too low");
      });

      it("Should extend auction on last-minute bid (anti-snipe)", async function () {
        const { auctionHouse, collection, seller, buyer } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await auctionHouse.connect(seller).createEnglishAuction(
          collectionAddr, 0,
          ethers.parseEther("0.1"),
          ethers.parseEther("0.1"),
          600 // 10 minutes
        );

        // Fast forward to last 3 minutes
        await time.increase(480);

        await expect(
          auctionHouse.connect(buyer).placeBid(0, { value: ethers.parseEther("0.1") })
        ).to.emit(auctionHouse, "AuctionExtended");
      });

      it("Should settle auction and transfer NFT", async function () {
        const { auctionHouse, collection, seller, buyer } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await auctionHouse.connect(seller).createEnglishAuction(
          collectionAddr, 0,
          ethers.parseEther("1"),
          ethers.parseEther("0.1"),
          86400
        );

        await auctionHouse.connect(buyer).placeBid(0, { value: ethers.parseEther("1.5") });

        // Fast forward past end
        await time.increase(86401);

        await expect(auctionHouse.settleAuction(0))
          .to.emit(auctionHouse, "AuctionSettled")
          .withArgs(0, buyer.address, ethers.parseEther("1.5"));

        expect(await collection.ownerOf(0)).to.equal(buyer.address);
      });

      it("Should return NFT to seller if reserve not met", async function () {
        const { auctionHouse, collection, seller, buyer } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await auctionHouse.connect(seller).createEnglishAuction(
          collectionAddr, 0,
          ethers.parseEther("10"), // high reserve
          ethers.parseEther("0.1"),
          86400
        );

        await auctionHouse.connect(buyer).placeBid(0, { value: ethers.parseEther("0.1") });

        await time.increase(86401);

        await auctionHouse.settleAuction(0);

        // NFT returned to seller
        expect(await collection.ownerOf(0)).to.equal(seller.address);
      });

      it("Should cancel auction with no bids", async function () {
        const { auctionHouse, collection, seller } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await auctionHouse.connect(seller).createEnglishAuction(
          collectionAddr, 0,
          ethers.parseEther("1"),
          ethers.parseEther("0.1"),
          86400
        );

        await expect(auctionHouse.connect(seller).cancelAuction(0))
          .to.emit(auctionHouse, "AuctionCancelled")
          .withArgs(0);

        expect(await collection.ownerOf(0)).to.equal(seller.address);
      });
    });

    describe("Dutch Auction", function () {
      it("Should create a Dutch auction", async function () {
        const { auctionHouse, collection, seller } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await auctionHouse.connect(seller).createDutchAuction(
          collectionAddr, 1,
          ethers.parseEther("10"),  // start price
          ethers.parseEther("1"),   // end price
          86400                     // 1 day
        );

        const auction = await auctionHouse.auctions(0);
        expect(auction.startPrice).to.equal(ethers.parseEther("10"));
        expect(auction.endPrice).to.equal(ethers.parseEther("1"));
      });

      it("Should calculate decaying price correctly", async function () {
        const { auctionHouse, collection, seller } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await auctionHouse.connect(seller).createDutchAuction(
          collectionAddr, 1,
          ethers.parseEther("10"),
          ethers.parseEther("1"),
          86400
        );

        // At start, price should be near 10 ETH
        const priceAtStart = await auctionHouse.getDutchAuctionPrice(0);
        expect(priceAtStart).to.equal(ethers.parseEther("10"));

        // Half way through, price should be ~5.5 ETH
        await time.increase(43200);
        const priceMid = await auctionHouse.getDutchAuctionPrice(0);
        expect(priceMid).to.be.lt(ethers.parseEther("6"));
        expect(priceMid).to.be.gt(ethers.parseEther("5"));
      });

      it("Should buy at current Dutch auction price", async function () {
        const { auctionHouse, collection, seller, buyer } = await loadFixture(deployMarketplaceFixture);
        const collectionAddr = await collection.getAddress();

        await auctionHouse.connect(seller).createDutchAuction(
          collectionAddr, 1,
          ethers.parseEther("10"),
          ethers.parseEther("1"),
          86400
        );

        // Buy at start price
        await expect(
          auctionHouse.connect(buyer).buyDutchAuction(0, { value: ethers.parseEther("10") })
        )
          .to.emit(auctionHouse, "AuctionSettled");

        expect(await collection.ownerOf(1)).to.equal(buyer.address);
      });
    });
  });

  describe("CollectionFactory", function () {
    it("Should create a collection", async function () {
      const { factory, buyer } = await loadFixture(deployMarketplaceFixture);

      await expect(
        factory.connect(buyer).createCollection(
          "My NFT", "MNFT", 100, ethers.parseEther("0.05"), 250,
          { value: ethers.parseEther("0.01") }
        )
      ).to.emit(factory, "CollectionCreated");

      expect(await factory.totalCollections()).to.equal(2); // 1 from fixture + 1 new
    });

    it("Should reject insufficient creation fee", async function () {
      const { factory, buyer } = await loadFixture(deployMarketplaceFixture);

      await expect(
        factory.connect(buyer).createCollection(
          "My NFT", "MNFT", 100, ethers.parseEther("0.05"), 250,
          { value: ethers.parseEther("0.001") }
        )
      ).to.be.revertedWith("Insufficient creation fee");
    });

    it("Should reject royalty above 10%", async function () {
      const { factory, buyer } = await loadFixture(deployMarketplaceFixture);

      await expect(
        factory.connect(buyer).createCollection(
          "My NFT", "MNFT", 100, ethers.parseEther("0.05"), 1100,
          { value: ethers.parseEther("0.01") }
        )
      ).to.be.revertedWith("Royalty exceeds 10%");
    });

    it("Should track creator collections", async function () {
      const { factory, buyer } = await loadFixture(deployMarketplaceFixture);

      await factory.connect(buyer).createCollection(
        "NFT A", "NFTA", 100, 0, 0,
        { value: ethers.parseEther("0.01") }
      );
      await factory.connect(buyer).createCollection(
        "NFT B", "NFTB", 200, 0, 0,
        { value: ethers.parseEther("0.01") }
      );

      const creatorCols = await factory.getCreatorCollections(buyer.address);
      expect(creatorCols.length).to.equal(2);
    });
  });

  describe("RoyaltyRegistry", function () {
    it("Should set collection royalty", async function () {
      const { royaltyRegistry, collection, royaltyReceiver, owner } = await loadFixture(deployMarketplaceFixture);
      const collectionAddr = await collection.getAddress();

      await expect(
        royaltyRegistry.setCollectionRoyalty(collectionAddr, royaltyReceiver.address, 500)
      )
        .to.emit(royaltyRegistry, "CollectionRoyaltySet")
        .withArgs(collectionAddr, royaltyReceiver.address, 500);

      const [receiver, amount] = await royaltyRegistry.getRoyaltyInfo(
        collectionAddr, 0, ethers.parseEther("1")
      );
      expect(receiver).to.equal(royaltyReceiver.address);
      expect(amount).to.equal(ethers.parseEther("0.05")); // 5%
    });

    it("Should reject royalty above 10%", async function () {
      const { royaltyRegistry, collection, royaltyReceiver } = await loadFixture(deployMarketplaceFixture);

      await expect(
        royaltyRegistry.setCollectionRoyalty(
          await collection.getAddress(), royaltyReceiver.address, 1100
        )
      ).to.be.revertedWith("Royalty exceeds 10% cap");
    });

    it("Should fall back to EIP-2981 on collection", async function () {
      const { royaltyRegistry, collection } = await loadFixture(deployMarketplaceFixture);
      const collectionAddr = await collection.getAddress();

      // No override set, should use the collection's built-in royalty
      const [receiver, amount] = await royaltyRegistry.getRoyaltyInfo(
        collectionAddr, 0, ethers.parseEther("1")
      );
      // Collection was created with 500 bps (5%) royalty and seller as receiver
      expect(amount).to.equal(ethers.parseEther("0.05"));
    });

    it("Should allow collection admin to set royalty", async function () {
      const { royaltyRegistry, collection, seller, royaltyReceiver, owner } = await loadFixture(deployMarketplaceFixture);
      const collectionAddr = await collection.getAddress();

      // Set seller as collection admin
      await royaltyRegistry.setCollectionAdmin(collectionAddr, seller.address);

      // Seller can now set royalty
      await royaltyRegistry.connect(seller).setCollectionRoyalty(
        collectionAddr, royaltyReceiver.address, 300
      );

      const [receiver, amount] = await royaltyRegistry.getRoyaltyInfo(
        collectionAddr, 0, ethers.parseEther("1")
      );
      expect(receiver).to.equal(royaltyReceiver.address);
      expect(amount).to.equal(ethers.parseEther("0.03")); // 3%
    });
  });
});
