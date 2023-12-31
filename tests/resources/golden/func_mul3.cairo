// @post [ap - 1] == 15
func main() {
    [ap] = 5, ap++;
    call succ;
    ret;
}

// @post $Return.res == 3 * [fp - 3]
func succ(x) -> (res: felt) {
    [ap] = x, ap++;
    [ap] = [ap - 1] * 3, ap++;
    ret;
}
