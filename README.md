# Perpetual PWN

A fork of PWN Finance, adding the possibility for users to request perpetual loans.
With Perpetual loans, the borrower pays interest in a stream. If they close their stream without repaying the initial principal, the Lender can claim the collateral.

**Workflow:**

1. User requests perpetual loan
2. Lender sends offer
3. Borrower approves contract for transfers (ERC20.approve) and to open a stream for them (Superfluid ACL)
4. Borrower accepts offer, and this:
    - Creates a LOAN struct, where we added the "interestByTheSecond" attribute
    - Transfers the collateral to the vault
    - Transfers the loan amount to the borrower
    - Opens a stream from the borrower to the lender, with a flowrate based on "interestByTheSecond"
5. As long as the borrower is paying interest (the stream is open), the position is open
6. If the borrower wants to close their position, they call "repayLoan", which:
    - Checks the user has approved the contract for ERC20.approve and Superfluid ACL
    - Transfers the repayAmount (equal to borrowed amount) back to the lender
    - Closes the stream from the borrower to the lender
7. If the borrower interrupts their stream, or changes the flowrate, the lender can liquidate them:
    - Checks whether the stream is incorrect
    - Transfers the collateral to themselves
8. The borrower can, at any time, transfer the Borrow position to someone else. This will:
    - Close the stream to the existing owner
    - Open the stream to the new owner
    - Effectively moving the position, and the interest, to the new owner

In order for this to work, we have needed to make a few changes to the contract. Specifically, now the getStatus() function requires the _owner parameter, indicating the owner of the NFT who currently owns the position.

## Derisking

By continuously receiving their interest payments, Lenders are continuously de-risking their position. This allows them to provide loans on riskier assets simply by increasing the interest rate. 

## Composability

The Lenders hold an ERC1155 token representing their position. This can be transferred at will, and when transferred also transfers the attached "interest stream". This is effectively a tradeable yield-bearing asset, backed by collateral. A sort of convertible bond. 

The lack of a fixed duration for the positions significantly increases the fungibility of positions. By all having the same maturity (perpetual!) it's much simpler to bundle lending positions, creating lending "funds" or "vaults". 

## Position netting

Borrowers hold all liquidity in their own wallets, continuously streaming the interest to the lenders. Because of Superfluid's unique streaming model, where stream liquidity is part of a user's balance, and streams are netted in real time, a user can pay their interest directly from an incoming stream. This could be their streamed salary, some other income, or even a *lender* position.

This opens the possibility for lenders to use their income to pay interest at the same time. Enabling very strong capital efficiency and velocity in interest repayments.


