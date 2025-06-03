use starknet::ContractAddress;
pub mod erc20;
pub mod verify_sig;
#[starknet::interface]
pub trait IHelloStarknet<TContractState> {
    fn increase_balance(ref self: TContractState, amount: felt252);
    fn get_balance(self: @TContractState) -> felt252;
    fn validate_wallet(self: @TContractState, address: ContractAddress) -> bool;
    fn create_request(ref self: TContractState, recipient: ContractAddress, amount: u256) -> u256;
    fn pay_request(ref self: TContractState, request_id: u256);
    fn set_usdt_token(ref self: TContractState, token_address: ContractAddress);
}

#[starknet::contract]
mod HelloStarknet {
    use starknet::event::EventEmitter;
    use super::IHelloStarknet;
    use starknet::ContractAddress;
    use core::num::traits::Zero;
    use starknet::storage::StoragePathEntry;
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, Map, StorageMapWriteAccess,
    };
    use starknet::{get_block_timestamp, get_caller_address, get_tx_info};
    use crate::{erc20::IERC20Dispatcher, erc20::IERC20DispatcherTrait};
    #[storage]
    struct Storage {
        balance: felt252,
        requests: Map<u256, PaymentRequest>,
        request_counter: u256,
        usdt_token: ContractAddress,
        admin: ContractAddress,
    }

    #[event]
    #[derive(Copy, Drop, Debug, PartialEq, starknet::Event)]
    pub enum Event {
        QuickpayPaid: QuickpayPaid,
    }

    #[derive(Copy, Drop, Debug, PartialEq, starknet::Event)]
    pub struct QuickpayPaid {
        request_id: u256,
        payer: ContractAddress,
        amount: u256,
        timestamp: u64,
    }

    #[derive(Drop, Serde, Copy, starknet::Store)]
    struct PaymentRequest {
        recipient: ContractAddress,
        amount: u256,
        paid: bool,
        created_at: u64,
        paid_at: u64,
        payer: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let tx_info = get_tx_info();
        self.admin.write(tx_info.account_contract_address);
    }


    #[abi(embed_v0)]
    impl HelloStarknetImpl of IHelloStarknet<ContractState> {
        fn increase_balance(ref self: ContractState, amount: felt252) {
            assert(amount != 0, 'Amount cannot be 0');
            self.balance.write(self.balance.read() + amount);
        }

        fn get_balance(self: @ContractState) -> felt252 {
            self.balance.read()
        }

        fn validate_wallet(self: @ContractState, address: ContractAddress) -> bool {
            if address.is_zero() {
                return false;
            }
            true
        }

        fn create_request(
            ref self: ContractState, recipient: ContractAddress, amount: u256,
        ) -> u256 {
            let request_id = self.request_counter.read();
            let timestamp = get_block_timestamp();
            let new_request = PaymentRequest {
                recipient,
                amount,
                paid: false,
                created_at: timestamp,
                paid_at: 0_u64,
                payer: get_caller_address(),
            };

            self.requests.write(request_id, new_request);
            self.request_counter.write(request_id + 1_u256);
            request_id
        }

        fn set_usdt_token(ref self: ContractState, token_address: ContractAddress) {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), 'Only admin');
            self.usdt_token.write(token_address);
        }

        fn pay_request(ref self: ContractState, request_id: u256) {
            let payer = get_caller_address();

            let mut request = self.requests.entry(request_id).read();
            assert(!request.recipient.is_zero(), 'Request does not exist');
            assert(!request.paid, 'Request already paid');
            let usdt = IERC20Dispatcher { contract_address: self.usdt_token.read() };
            let success = usdt.transfer_from(payer, request.recipient, request.amount);
            assert(success, 'Transfer failed');

            request.paid = true;
            self.requests.write(request_id, request);
            self
                .emit(
                    Event::QuickpayPaid(
                        QuickpayPaid {
                            request_id,
                            payer: request.payer,
                            amount: request.amount,
                            timestamp: get_block_timestamp(),
                        },
                    ),
                );
        }
    }
}
