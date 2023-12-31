%lang starknet
from starkware.starknet.common.syscalls import get_contract_address

// @post $Return.res == get_contract_address()
func test_valid{syscall_ptr: felt*}() -> (res: felt) {
    let (res) = get_contract_address();
    return (res=res);
}

// @post $Return.res == 5
func test_invalid_1{syscall_ptr: felt*}() -> (res: felt) {
    let (res) = get_contract_address();
    return (res=res);
}

// @post $Return.res == get_contract_address()
func test_invalid_2{syscall_ptr: felt*}() -> (res: felt) {
    let res = 5;
    return (res=res);
}
