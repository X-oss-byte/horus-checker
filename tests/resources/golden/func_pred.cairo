// @post [ap - 1] == 41
func main() {
    [ap] = 42, ap++;
    call pred;
    ret;
}

// @post $Return.res == x - 1
func pred(x) -> (res: felt) {
    [ap] = [fp - 3], ap++;
    [ap] = [ap - 1] - 1, ap++;
    ret;
}
