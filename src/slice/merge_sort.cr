struct Slice(T)

  THRESHOLD = 8

  protected def self.merge_sort!(a, n)
   return if n < 2
   if n < THRESHOLD
     insertion_sort!(a, 0, n)
   end
   insertion_sort!(a, 0, n)
  end

  # insertion_sort! exists

  protected def self.merge_sort!(a, n, comp)
    return if n < 2
    insertion_sort!(a, 0, n, comp)
  end

end
