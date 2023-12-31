// @declare $x : felt
// @pre $x == x and $x > 0 and $x < 10
// @post $Return.res > 1
func test1(x: felt) -> (res: felt) {
    ap += [ap] + 1;
    let (y) = id(x);
    [ap] = y;
    ap += 2;

    // @invariant [ap - 2] == $x and $x > 0 and $x < 10
    lab:
    [ap] = [ap - 2], ap++;
    [ap] = [ap - 2] - 1, ap++;
    jmp lab if [ap - 1] != 0;
    return (res=[ap - 2] + 1);
}

// @declare $x : felt
// @pre x == $x
// @post $Return.res == $x
func id(x: felt) -> (res: felt) {
    return (res=x);
}
