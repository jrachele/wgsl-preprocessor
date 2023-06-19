#if test_condition
var a = 10;
#else
var a = 5;
#endif
#if false_condition
#if true_condition
// This should not be here!
#endif
#endif
