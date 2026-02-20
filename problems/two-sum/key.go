package main

// TwoSumSolution returns the indices of the two numbers such that they add up to target.
// It matches LeetCode's expected behavior for exactly one valid answer.
func TwoSumSolution(nums []int, target int) []int {
	seen := make(map[int]int, len(nums))
	for i, n := range nums {
		if j, ok := seen[target-n]; ok {
			return []int{j, i}
		}
		seen[n] = i
	}
	return nil
}
