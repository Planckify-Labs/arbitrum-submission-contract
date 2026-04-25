use anchor_lang::prelude::*;

declare_id!("9ZtzMfw1ra616vsdmKzzh2ebrJ779djXb9goTiSjtnSt");

#[program]
pub mod takumi_pay {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>) -> Result<()> {
        msg!("Greetings from: {:?}", ctx.program_id);
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize {}
