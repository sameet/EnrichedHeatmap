

# == title
# Normalize associations between genomic signals and target regions into a matrix
#
# == param
# -signal a `GenomicRanges::GRanges` object.
# -target a `GenomicRanges::GRanges` object.
# -extend extended base pairs to the upstream and downstream of ``target``. It can be a vector of length one or two.
#         If it is length one, it means extension to the upstream and downstream are the same.
# -w window size for splitting upstream and downstream.
# -value_column column index in ``signal`` that will be mapped to colors. If it is ``NULL``, an internal column
#         which all contains 1 will be used.
# -mapping_column mapping column to restrict overlapping between ``signal`` and ``target``. By default it tries to look for
#           all regions in ``signal`` that overlap with every target.
# -empty_value values for small windows that don't overlap with ``signal``. 
# -mean_mode when a window is not perfectly overlapped to ``signal``, how to summarize 
#        values to this window. See 'Details' section for a detailed explanation.
# -include_target  whether include ``target`` in the heatmap. If the width of all regions in ``target`` is 1, ``include_target``
#               is enforced to ``FALSE``.
# -target_ratio  the ratio of ``target`` in the full heatmap. If the value is 1, ``extend`` will be reset to 0.
# -k number of windows only when ``target_ratio = 1`` or ``extend == 0``, otherwise ignored.
# -smooth whether apply smoothing on rows in the matrix. 
# -smooth_fun the smoothing function that is applied to each row in the matrix. This self-defined function accepts a numeric
#    vector (may contains ``NA`` values) and returns a vector with same length. If the smoothing is failed, the function
#    should call `base::stop` to throw errors so that `normalizeToMatrix` can catch how many rows are failed in smoothing. 
#    See the default `default_smooth_fun` for example.
# -trim percent of extreme values to remove. IF it is a vector of length 2, it corresponds to the lower quantile and higher quantile.
#        e.g. ``c(0.01, 0.01)`` means to trim outliers less than 1st quantile and larger than 99th quantile.
#
# == details
# In order to visualize associations between ``signal`` and ``target``, the data is transformed into a matrix
# and visualized as a heatmap by `EnrichedHeatmap` afterwards.
#
# Upstream and downstream also with the target body are splitted into a list of small windows and overlap
# to ``signal``. Since regions in ``signal`` and small windows do not always 100 percent overlap, there are four different average modes:
# 
# Following illustrates different settings for ``mean_mode`` (note there is one signal region overlapping with other signals):
#
#       40      50     20     values in signal
#     ++++++   +++    +++++   signal
#            30               values in signal
#          ++++++             signal
#       =================     window (17bp), there are 4bp not overlapping to any signal region.
#         4  6  3      3      overlap
#
#     absolute: (40 + 30 + 50 + 20)/4
#     weighted: (40*4 + 30*6 + 50*3 + 20*3)/(4 + 6 + 3 + 3)
#     w0:       (40*4 + 30*6 + 50*3 + 20*3)/(4 + 6 + 3 + 3 + 4)
#     coverage: (40*4 + 30*6 + 50*3 + 20*3)/17
#
# To explain it more clearly, let's consider three scenarios:
#
# First, we want to calculate mean methylation from 3 CpG sites in a 20bp window. Since methylation
# is only measured at CpG site level, the mean value should only be calculated from the 3 CpG sites while not the non-CpG sites. In this
# case, ``absolute`` mode should be used here.
#
# Second, we want to calculate mean coverage in a 20bp window. Let's assume coverage is 5 in 1bp ~ 5bp, 10 in 11bp ~ 15bp and 20 in 16bp ~ 20bp.
# Since converage is kind of attribute for all bases, all 20 bp should be taken into account. Thus, here ``w0`` mode should be used
# which also takes account of the 0 coverage in 6bp ~ 10bp. The mean coverage will be caculated as ``(5*5 + 10*5 + 20*5)/(5+5+5+5)``.
#
# Third, genes have multiple transcripts and we want to calculate how many transcripts eixst in a certain position in the gene body.
# In this case, values associated to each transcript are binary (either 1 or 0) and ``coverage`` mean mode should be used.
#
# == value
# A matrix with following additional attributes:
#
# -``upstream_index`` column index corresponding to upstream of ``target``
# -``target_index`` column index corresponding to ``target``
# -``downstream_index`` column index corresponding to downstream of ``target``
# -``extend`` extension on upstream and downstream
# -``smooth`` whether smoothing was applied on the matrix
# -``failed_rows`` index of rows which are failed for smoothing
#
# The matrix is wrapped into a simple ``normalizeToMatrix`` class.
#
# == author
# Zuguang Gu <z.gu@dkfz.de>
#
# == example
# signal = GRanges(seqnames = "chr1", 
# 	  ranges = IRanges(start = c(1, 4, 7, 11, 14, 17, 21, 24, 27),
#                      end = c(2, 5, 8, 12, 15, 18, 22, 25, 28)),
#     score = c(1, 2, 3, 1, 2, 3, 1, 2, 3))
# target = GRanges(seqnames = "chr1", ranges = IRanges(start = 10, end = 20))
# normalizeToMatrix(signal, target, extend = 10, w = 2)
# normalizeToMatrix(signal, target, extend = 10, w = 2, include_target = TRUE)
# normalizeToMatrix(signal, target, extend = 10, w = 2, value_column = "score")
#
normalizeToMatrix = function(signal, target, extend = 5000, w = max(extend)/50, 
	value_column = NULL, mapping_column = NULL, empty_value = ifelse(smooth, NA, 0), 
	mean_mode = c("absolute", "weighted", "w0", "coverage"), include_target = any(width(target) > 1), 
	target_ratio = ifelse(all(extend == 0), 1, 0.1), k = min(c(20, min(width(target)))), 
	smooth = FALSE, smooth_fun = default_smooth_fun, trim = 0) {

	signal_name = deparse(substitute(signal))
	target_name = deparse(substitute(target))

	if(abs(target_ratio - 1) < 1e-6 || abs(target_ratio) >= 1) {
		if(!all(extend == 0)) warning("Rest `extend` to 0 when `target_ratio` is larger than or euqal to 1.")
		extend = c(0, 0)
	} else if(all(extend == 0)) {
		warning("Reset `target_ratio` to 1 when `extend` is 0.")
		target_ratio = 1
	}
	if(abs(target_ratio) > 1) target_ratio = 1

	target_is_single_point = all(width(target) <= 1)

	# if(s > 1) {
	# 	n = length(target)
	# 	if(s > n) s = n
	# 	x = seq(1, n, by = s)
	# 	if(x < n) x = c(x, n)
	# 	start_index = x[-length(x)]
	# 	end_index = x[-1] - 1
	# 	end_index[length(end_index)] = x[length(x)]

	# 	lt = lapply(seq_along(start_index), function(i) {
	# 		normalizeToMatrix(signal, target[ start_index[i]:end_index[i] ], extend = extend, w = w, 
	# 			value_column = value_column, mapping_column = mapping_column,
	# 			empty_value = empty_value, mean_mode = mean_mode, include_target = include_target,
	# 			target_ratio = target_ratio, smooth = smooth, s = 1, trim = 0)
	# 	})

	# 	upstream_index = attr(lt[[1]], "upstream_index")
	# 	target_index = attr(lt[[1]], "target_index")
	# 	downstream_index = attr(lt[[1]], "downstream_index")
	# 	extend = attr(lt[[1]], "extend")
	# 	smooth = attr(lt[[1]], "smooth")

	# 	mat = do.call("rbind", lt)

	# 	attr(mat, "upstream_index") = upstream_index
	# 	attr(mat, "target_index") = target_index
	# 	attr(mat, "downstream_index") = downstream_index
	# 	attr(mat, "extend") = extend
	# 	attr(mat, "smooth") = smooth
	# 	attr(mat, "signal_name") = signal_name
	# 	attr(mat, "target_name") = target_name
	# 	attr(mat, "target_is_single_point") = target_is_single_point

	# 	if(trim > 0) {
	#   		q1 = quantile(mat, trim/2, na.rm = TRUE)
	#   		q2 = quantile(mat, 1 - trim/2, na.rm = TRUE)
	#   		mat[mat <= q1] = q1
	#   		mat[mat >= q2] = q2
	#   	}
	#   	class(mat) = c("normalizedMatrix", "matrix")
	# 	return(mat)
	# }

	if(target_is_single_point) {
		if(include_target) {
			warning("Width of `target` are all 1, `include_target` is set to `FALSE`.")
		}
		include_target = FALSE
	}
  
	if(length(extend) == 1) extend = c(extend, extend)
	if(extend[1] > 0) {
		if(extend[1] %% w > 0) {
			warning("Length of upstream extension is not completely divisible by `w`.")
			extend[1] = extend[1] - extend[1] %% w
		}
	}
	if(extend[2] > 0) {
		if(extend[2] %% w > 0) {
			warning("Length of downstream extension is not completely divisible by `w`.")
			extend[2] = extend[2] - extend[2] %% w
		}
	}

	.seq = function(start, end, by = 1) {
		if(end < start) {
			return(integer(0))
		} else {
			seq(start, end, by = by)
		}
	}
  	
  	if(target_is_single_point) {
  		# do not need to separate upstream and downstream
  		# and it makes the boundary between upstream and downstream smoothing
  		suppressWarnings(both <- promoters(target, upstream = extend[1], downstream = extend[2]))

		mat_both = makeMatrix(signal, both, w = w, value_column = value_column, mapping_column = mapping_column, 
			empty_value = empty_value, mean_mode = mean_mode)
		i = round(extend[1]/(extend[1] + extend[2]) * ncol(mat_both))  # assume
		# if(i < 2 | ncol(mat_both) - i < 2) {
		# 	stop("Maybe `w` is too large or one of `extend` is too small.")
		# }
		mat_upstream = mat_both[, .seq(1, i), drop = FALSE]
		mat_downstream = mat_both[, .seq(i+1, ncol(mat_both)), drop = FALSE]
	  
  	} else {
		# extend and normalize in upstream 
		if(extend[1] <= 0) {
			mat_upstream = matrix(0, nrow = length(target), ncol = 0)
		} else {
			suppressWarnings(upstream <- promoters(target, upstream = extend[1], downstream = 0))
			mat_upstream = makeMatrix(signal, upstream, w = w, value_column = value_column, mapping_column = mapping_column, 
				empty_value = empty_value, mean_mode = mean_mode)
		}

		# extend and normalize in downstream
		e = ifelse(strand(target) == "-", start(target) - 1, end(target) + 1)
		end_target = GRanges(seqnames = seqnames(target),
	                         ranges = IRanges(start = e, end = e),
	                         strand = strand(target))
		if(extend[2] <= 0) {
			mat_downstream = matrix(0, nrow = length(target), ncol = 0)
		} else {
			suppressWarnings(downstream <- promoters(end_target, upstream = 0, downstream = extend[2]))
			names(downstream) = names(target)
		  
			mat_downstream = makeMatrix(signal, downstream, w = w, value_column = value_column, mapping_column = mapping_column, 
				empty_value = empty_value, mean_mode = mean_mode)
		}
	}

	if(include_target) {
		if(!all(extend == 0)) {
			k = round((ncol(mat_upstream) + ncol(mat_downstream)) * target_ratio/(1-target_ratio))
			if(k < 1) k = 1
		} 
		mat_target = makeMatrix(signal, target, k = k, value_column = value_column, mapping_column = mapping_column, empty_value = empty_value, mean_mode = mean_mode)
	} else {
		mat_target = matrix(0, nrow = length(target), ncol = 0)
	}

  	mat = cbind(mat_upstream, mat_target, mat_downstream)

  	max_v = max(mat, na.rm = TRUE)
  	min_v = min(mat, na.rm = TRUE)
  	# apply smoothing on rows in mat
  	failed_rows = NULL
  	
	if(smooth) {
		i_row = 0
		ow = options("warn")[[1]]
		mat = t(apply(mat, 1, function(x) {
			i_row <<- i_row + 1

			oe = try(x <- suppressWarnings(smooth_fun(x)), silent = TRUE)
			if(inherits(oe, "try-error")) {
				failed_rows <<- c(failed_rows, i_row)
			}
			return(x)
		}))
		options(warn = ow)
		
		if(!is.null(failed_rows)) {
			if(length(failed_rows) == 1) {
				msg = paste(strwrap(paste0("Smoothing is failed for one row because there are very few signals overlapped to it. Please use `attr(mat, 'failed_rows')` to get the index of the failed row and consider to remove it.\n")), collapse = "\n")
			} else {
				msg = paste(strwrap(paste0("Smoothing are failed for ", length(failed_rows), " rows because there are very few signals overlapped to them. Please use `attr(mat, 'failed_rows')` to get the index of failed rows and consider to remove them.\n")), collapse = "\n")
			}
			msg = paste0("\n", msg, "\n")
			warning(msg)
		}
	}
	
	upstream_index = seq_len(ncol(mat_upstream))
	target_index = seq_len(ncol(mat_target)) + ncol(mat_upstream)	
	downstream_index = seq_len(ncol(mat_downstream)) + ncol(mat_upstream) + ncol(mat_target)

	attr(mat, "upstream_index") = upstream_index
	attr(mat, "target_index") = target_index
	attr(mat, "downstream_index") = downstream_index
	attr(mat, "extend") = extend
	attr(mat, "smooth") = smooth
	attr(mat, "signal_name") = signal_name
	attr(mat, "target_name") = target_name
	attr(mat, "target_is_single_point") = target_is_single_point
	attr(mat, "failed_rows") = failed_rows
	attr(mat, "empty_value") = empty_value

	.paste0 = function(a, b) {
		if(length(a) == 0 || length(b) == 0) {
			return(NULL)
		} else {
			paste0(a, b)
		}
	}

	# dimension names are mainly for debugging
  	rownames(mat) = names(target)
  	if(ncol(mat_target)) {
  		colnames(mat) = c(.paste0("u", seq_along(upstream_index)), .paste0("t", seq_along(target_index)), .paste0("d", seq_along(downstream_index)))
  	} else {
  		colnames(mat) = c(.paste0("u", seq_along(upstream_index)), .paste0("d", seq_along(downstream_index)))
  	}
  	if(length(trim) == 1) trim = c(trim, trim)
	q1 = quantile(mat, trim[1], na.rm = TRUE)
	q2 = quantile(mat, 1 - trim[2], na.rm = TRUE)
	mat[mat <= q1] = q1
	mat[mat >= q2] = q2
  	
  	mat[mat <= min_v] = min_v
  	mat[mat >= max_v] = max_v
	class(mat) = c("normalizedMatrix", "matrix")
	return(mat)
}

# 
# -gr input regions
# -target the upstream part or body part
# -window absolute size (100) or relative size(0.1)
# -value_column
# -mean_mode how to calculate mean value in a window
#
# == example
# gr = GRanges(seqnames = "chr1", ranges = IRanges(start = c(1, 4, 7), end = c(2, 5, 8)))
# target = GRanges(seqnames = "chr1", ranges =IRanges(start = 1, end = 10))
# makeMatrix(gr, target, w = 2)
#
makeMatrix = function(gr, target, w = NULL, k = NULL, value_column = NULL, mapping_column = mapping_column, empty_value = 0,
    mean_mode = c("absolute", "weighted", "w0", "coverage"), direction = c("normal", "reverse")) {
  
	if(is.null(value_column)) {
		gr$..value = rep(1, length(gr))
		value_column = "..value"
	}
  
	# split `target` into small windows
	target_windows = makeWindows(target, w = w, k = k, direction = direction)
 	strand(target_windows) = "*"
 	strand(gr) = "*"
 	
	# overlap `gr` to `target_windows`
	mtch = findOverlaps(gr, target_windows)
	mtch = as.matrix(mtch)
	
	# add a `value` column in `target_window` which is the mean value for intersected gr
	# in `target_window`
	m_gr = gr[ mtch[, 1] ]
	m_target_windows = target_windows[ mtch[, 2] ]

	# subset `m_gr` and `m_target_windows` based on `mapping_column`
	if(!is.null(mapping_column)) {
		
		mapping = mcols(m_gr)[[mapping_column]]
		if(is.numeric(mapping)) {
			l = mapping == m_target_windows$.i_query
		} else {
			if(is.null(names(target))) {
				stop("`mapping_column` in `gr` is mapped to the names of `target`, which means `target` should have names.")
			} else {
				l = mapping == names(target)[m_target_windows$.i_query]
			}
		}

		m_gr = m_gr[l]
		m_target_windows = m_target_windows[l]
		mtch = mtch[l , , drop = FALSE]
	}

	# the value associated with `gr`
	v = mcols(m_gr)[[value_column]]

	mean_mode = match.arg(mean_mode)[1]

	if(length(mtch)) {
		if(mean_mode == "w0") {
			mintersect = pintersect(m_gr, m_target_windows)
			w = width(mintersect)
			target_windows_list = split(ranges(m_gr), mtch[, 2])
			target_windows2 = target_windows[as.numeric(names(target_windows_list))]
			cov = coverage(target_windows_list, shift = -start(target_windows2), width = width(target_windows2))
			#non_intersect_width = sapply(cov, function(x) sum(x == 0))
			non_intersect_width = sapply(cov@listData, function(x) {ind = x@values == 0;sum(x@lengths[ind])})
			x = tapply(w*v, mtch[, 2], sum, na.rm = TRUE) / (tapply(w, mtch[, 2], sum, na.rm = TRUE) + non_intersect_width)
		} else if(mean_mode == "coverage") {
			mintersect = pintersect(m_gr, m_target_windows)
			p = width(mintersect)/width(m_target_windows)
			x = tapply(p*v, mtch[, 2], sum, na.rm = TRUE)
		} else if(mean_mode == "absolute") {
			x = tapply(v, mtch[, 2], mean, na.rm = TRUE)
		} else {
			mintersect = pintersect(m_gr, m_target_windows)
			w = width(mintersect)
			x = tapply(w*v, mtch[, 2], sum, na.rm = TRUE) / tapply(w, mtch[, 2], sum, na.rm = TRUE)
		}
		v2 = rep(empty_value, length(target_windows))
		v2[ as.numeric(names(x)) ] = x
	} else {
		v2 = rep(empty_value, length(target_windows))
	}

	target_windows$..value = v2

	# transform into a matrix
	tb = table(target_windows$.i_query)
	target_strand = strand(target)
	column_index = mapply(as.numeric(names(tb)), tb, FUN = function(i, n) {
		if(as.vector(target_strand[i] == "-")) {
			rev(seq_len(n))
		} else {
			seq_len(n)
		}
	}, SIMPLIFY = FALSE)
	column_index = do.call("cbind", column_index)

	# is column_index has the same length for all regions in target?
	# if extension of upstream are the same or split body into k pieces,
	# then all column index has the same length
	# if it is not the same, throw error!
	if(!is.matrix(column_index)) {
		stop("numbers of columns are not the same.")
	}
  
	mat = matrix(empty_value, nrow = length(target), ncol = dim(column_index)[1])
	mat[ target_windows$.i_query + (as.vector(column_index) - 1)* nrow(mat) ] = target_windows$..value

	# findOverlaps may use a lot of memory
	rm(list = setdiff(ls(), "mat"))
	gc(verbose = FALSE)

	return(mat)
}

# == title
# Split regions into windows
#
# == param
# -query a `GenomicRanges::GRanges` object.
# -w window size, a value larger than 1 means the number of base pairs and a value between 0 and 1
#    is the percent to the current region.
# -k number of partitions for each region. If it is set, all other arguments are ignored.
# -direction where to start the splitting. See 'Details' section.
# -short.keep if the the region can not be splitted equally under the window size, 
#             whether to keep the windows that are smaller than the window size. See 'Details' section.
#
# == details
# Following illustrates the meaning of ``direction`` and ``short.keep``:
#
#     ----->----  one region, split by 3bp window (">" means the direction of the sequence)
#     aaabbbccc   direction = "normal",  short.keep = FALSE
#     aaabbbcccd  direction = "normal",  short.keep = TRUE
#      aaabbbccc  direction = "reverse", short.keep = FALSE
#     abbbcccddd  direction = "reverse", short.keep = TRUE
#     
#
# == value
# A `GenomicRanges::GRanges` object with two additional columns attached:
# 
# - ``.i_query`` which contains the correspondance between small windows and original regions in ``query``
# - ``.i_window`` which contains the index of the small window on the current region.
#
# == author
# Zuguang gu <z.gu@dkfz.de>
#
# == example
# query = GRanges(seqnames = "chr1", ranges = IRanges(start = c(1, 11, 21), end = c(10, 20, 30)))
# makeWindows(query, w = 2)
# makeWindows(query, w = 0.2)
# makeWindows(query, w = 3)
# makeWindows(query, w = 3, direction = "reverse")
# makeWindows(query, w = 3, short.keep = TRUE)
# makeWindows(query, w = 3, direction = "reverse", short.keep = TRUE)
# makeWindows(query, w = 12)
# makeWindows(query, w = 12, short.keep = TRUE)
# makeWindows(query, k = 2)
# makeWindows(query, k = 3)
# query = GRanges(seqnames = "chr1", ranges = IRanges(start = c(1, 11, 31), end = c(10, 30, 70)))
# makeWindows(query, w = 2)
# makeWindows(query, w = 0.2)
#
makeWindows = function(query, w = NULL, k = NULL, direction = c("normal", "reverse"), 
	short.keep = FALSE) {

	direction = match.arg(direction)[1]
  
	if(is.null(w) & is.null(k)) {
		stop("You should define either `w` or `k`.")
	}
	ostart = start(query)
	oend = end(query)
  
	if(!is.null(k)) {
		pos = mapply(ostart, oend, FUN = function(s, e) {
			x = seq(s, e, length = k+1)
			y = round(x[-1])
			x = round(x[-length(x)])
			y[-k] = ifelse(y[-k] > x[-k], y[-k] - 1, y[-k])
			return(list(start = x, end = y))
		})
	} else {

		if(direction == "normal") {
			if(w >= 1) {
				w = as.integer(w)
				pos = mapply(ostart, oend, FUN = function(s, e) {
					x = seq(s, e, by = w)
					y = x + w - 1
					y = ifelse(y > e, e, y)
					if(!short.keep) {
						l = (y-x+1) == w
						x = x[l]
						y = y[l]
					}
					return(list(start = x, end = y))
				})
			} else if(w > 0 & w < 1) {
				pos = mapply(ostart, oend, FUN = function(s, e) {
					w = as.integer(round(e - s + 1)*w)
					x = seq(s, e, by = w)
					y = x + w - 1
					y = ifelse(y > e, e, y)
					if(!short.keep) {
						l = (y-x+1) == w
						x = x[l]
						y = y[l]
					}
					return(list(start = x, end = y))
				})
			} else {
				stop("`w` is wrong.")
			}
		} else {
			if(w >= 1) {
				w = as.integer(w)
				pos = mapply(ostart, oend, FUN = function(s, e) {
					y = seq(e, s, by = -w)
					x = y - w + 1
					x = ifelse(x < s, s, x)
					if(!short.keep) {
						l = (y-x+1) == w
						x = x[l]
						y = y[l]
					}
					return(list(start = rev(x), end = rev(y)))
				})
			} else if(w > 0 & w < 1) {
				pos = mapply(ostart, oend, FUN = function(s, e) {
					w = as.integer(round(e - s + 1)*w)
					y = seq(e, s, by = -w)
					x = y - w + 1
					x = ifelse(x < s, s, x)
					if(!short.keep) {
						l = (y-x+1) == w
						x = x[l]
						y = y[l]
					}
					return(list(start = rev(x), end = rev(y)))
				})
			} else {
				stop("`w` is wrong.")
			}
		}
	}
  
	# check start and end

	start = unlist(pos[1, ])
	end = unlist(pos[2, ])
	i_query = rep(seq_len(ncol(pos)), times = sapply(pos[1, ], length))
	i_window = unlist(lapply(pos[1, ], seq_along))  # which window from left to right
	chr = seqnames(query)[i_query]
	strand = strand(query)[i_query]

	gr = GRanges(seqnames = chr,
		         ranges = IRanges(start = start,
		         	              end = end),
		         strand = strand,
		         .i_query = i_query,
		         .i_window = i_window)
	return(gr)

}

# == title
# Subset normalized matrix by rows
#
# == param
# -x the normalized matrix returned by `normalizeToMatrix`
# -i row index
# -j column index
# -drop whether drop the dimension
#
# == value
# A ``normalizedMatrix`` class object.
#
# == author
# Zuguang Gu <z.gu@dkfz.de>
#
"[.normalizedMatrix" = function(x, i, j, drop = FALSE) {
	
	attr = attributes(x)
	attributes(x) = NULL
	for(bb in intersect(names(attr), c("dim", "dimnames"))) {
		attr(x, bb) = attr[[bb]]
	}
	if(!missing(i) && !missing(j)) {
		return(x[i, j, drop = FALSE])
	}
	if(nargs() == 2) {
		return(x[i])
	}
	if(nargs() == 3 && missing(i)) {
		return(x[, j])
	}
	if(missing(i)) {
		return(x[i, j, drop = drop])
	}
	x = x[i, , drop = FALSE]
	for(bb in setdiff(names(attr), c("dim", "dimnames"))) {
		attr(x, bb) = attr[[bb]]
	}
	return(x)
}

rbind.normalizedMatrix = function(..., deparse.level = 1) {
	mat_list = list(...)
	rbind_matrix = selectMethod("rbind", signature = "matrix")
	mat = do.call("rbind_matrix", mat_list)
	mat = copyAttr(mat_list[[1]], mat)
	return(mat)
}

# == title
# Print normalized matrix
#
# == param
# -x the normalized matrix returned by `normalizeToMatrix`
# -... other arguments
#
# == value
# No value is returned.
#
# == author
# Zuguang Gu <z.gu@dkfz.de>
#
print.normalizedMatrix = function(x, ...) {

	upstream_index = attr(x, "upstream_index")
	target_index = attr(x, "target_index")
	downstream_index = attr(x, "downstream_index")
	extend = attr(x, "extend")
	smooth = attr(x, "smooth")
	signal_name = attr(x, "signal_name")
	target_name = attr(x, "target_name")
	target_is_single_point = attr(x, "target_is_single_point")

	op = qq.options(READ.ONLY = FALSE)
    on.exit(qq.options(op))
    qq.options(code.pattern = "@\\{CODE\\}")

	qqcat("Normalize @{signal_name} to @{target_name}:\n")
	qqcat("  Upstream @{extend[1]} bp (@{length(upstream_index)} window@{ifelse(length(upstream_index) > 1, 's', '')})\n")
	qqcat("  Downstream @{extend[2]} bp (@{length(downstream_index)} window@{ifelse(length(upstream_index) > 1, 's', '')})\n")
	if(length(target_index) == 0) {
		qqcat("  Not include target regions\n")
	} else {
		if(target_is_single_point) {
			qqcat("  Include target regions (width = 1)\n")
		} else {
			qqcat("  Include target regions (@{length(target_index)} window@{ifelse(length(target_index) > 1, 's', '')})\n")
		}
	}
	qqcat("  @{nrow(x)} signal region@{ifelse(nrow(x) > 1, 's', '')}\n")
}

# == title
# Copy attributes to another object
#
# == param
# -x object 1
# -y object 2
#
# == details
# The `normalizeToMatrix` object actually is a matrix but with more additional attributes attached.
# This function is used to copy these new attributes when dealing with the matrix.
#
# == author
# Zuguang Gu <z.gu@dkfz.de>
#
# == example
# NULL
copyAttr = function(x, y) {
	if(!identical(ncol(x), ncol(y))) {
		stop("x and y should have same number of columns.\n")
	}
	attr = attributes(x)
	for(bb in setdiff(names(attr), c("dim"))) {
		if(bb == "dimnames") {
			attr(y, bb)[[2]] = attr[[bb]][[2]]  # set same column names
		} else {
			attr(y, bb) = attr[[bb]]
		}
	}
	attr(y, "signal_name") = "\b"
	return(y)
}

# == title
# Get signals from a list
#
# == param
# -lt a list of objects which are returned by `normalizeToMatrix`. Objects in the list should come from same settings.
# -fun a self-defined function which gives mean signals across samples. If we assume the objects in the list correspond
#        to different samples, then different regions in the targets are the first dimension, different positions
#        upstream or downstream of the targets are the second dimension, and different samples are the third dimension.
#        This self-defined function can have one argument which is the vector containing values in different samples
#        in a specific position to a specific target region. Or it can have a second argument which is the index for 
#        the current target.
#
# == details
# Let's assume you have a list of histone modification signals for different samples and you want
# to visualize the mean pattern across samples. You can first normalize histone mark signals for each sample and then
# calculate means values across all samples. In following example code, ``hm_gr_list`` is a list of ``GRanges`` objects
# which contain positions of histone modifications, ``tss`` is a ``GRanges`` object containing positions of gene TSS.
#
#     mat_list = NULL
#     for(i in seq_along(hm_gr_list)) {
#         mat_list[[i]] = normalizeToMatrix(hm_gr_list[[i]], tss, value_column = "density")
#     }
#
# Applying ``getSignalsFromList()`` to ``mat_list``, it gives a new normalized matrix which contains mean signals and can
# be directly used in ``EnrichedHeatmap()``.
#
#     mat = getSignalsFromList(mat_list)
#     EnrichedHeatmap(mat)
#
# Next let's consider a second scenario: we want to see the correlation between histone modification and gene expression.
# In this case, ``fun`` can have a second argument so that users can correspond histone signals to the expression of the
# associated gene. In following code, ``expr`` is a matrix of expression, columns in ``expr`` correspond to elements in ``hm_gr_list``,
# rows in ``expr`` are same as ``tss``.
# 
#     mat = getSignalsFromList(mat_list, 
#         fun = function(x, i) cor(x, expr[i, ], method = "spearman"))
#
# Then ``mat`` here can be used to visualize how gene expression is correlated to histone modification around TSS.
#
#     EnrichedHeatmap(mat)
#
#
# == value
# A `normalizeToMatrix` object which can be directly used for `EnrichedHeatmap`.
# 
# == author
# Zuguang Gu <z.gu@dkfz.de>
#
# == example
# NULL
getSignalsFromList = function(lt, fun = function(x) mean(x, na.rm = TRUE)) {

	if(!inherits(lt, "list")) {
		stop("`lt` should be a list of objects which are returned by `normalizeToMatrix()`.")
	}

	if(!all(sapply(lt, inherits, "normalizedMatrix"))) {
		stop("`lt` should be a list of objects which are returned by `normalizeToMatrix()`.")
	}

	n = length(lt)
	# if(n > 1) {
	#	for(i in seq_len(n-1)) {
	#		attr1 = attr(lt[[i]], c("upstream_index", "target_index", "downstream_index", "extend"))
	#		attr2 = attr(lt[[i+1]], c("upstream_index", "target_index", "downstream_index", "extend"))
	#		if(!identical(attr1, attr2)) {
	#			stop("Objects in `lt` should have same settings.")
	#		}
	#	}
	#}

	for(i in seq_len(n)) {
		tm = lt[[i]]
	    if(!exists("arr")) {
	    	arr = array(dim = c(dim(tm), length(lt)))
	    }
	    arr[, , i] = tm
	}

	if(identical(fun, mean)) {
		fun = function(x) mean(x, na.rm = TRUE)
	} else if(identical(fun, median)) {
		fun = function(x) median(x, na.rm = TRUE)
	} else if(identical(fun, max)) {
		fun = function(x) max(x, na.rm = TRUE)
	} else if(identical(fun, min)) {
		fun = function(x) min(x, na.rm = TRUE)
	} 

	if(length(as.list(fun)) == 2) {
		m = apply(arr[, , ,drop = FALSE], c(1, 2), fun)
	} else if(length(as.list(fun)) == 3) {
		m = matrix(nrow = nrow(lt[[1]]), ncol = ncol(lt[[1]]))
		for(i in seq_len(nrow(m))) {
			for(j in seq_len(ncol(m))) {
				m[i, j] = fun(arr[i, j, ], i)
			}
		}
	} else {
		stop("`fun` can only have one or two arguments.")
	}
	m = copyAttr(m, lt[[1]])
	return(m)
}

# == title
# Default smooth function
#
# == param
# -x input numeric vector
#
# == details
# The smooth function is applied to every row in the normalized matrix. For this default smooth function,
# `locfit::locfit` is first tried on the vector. If there is error, `stats::loess` smoothing is tried afterwards.
# If both smoothing are failed, there will be an error.
#
# == author
# Zuguang Gu <z.gu@dkfz.de>
#
default_smooth_fun = function(x) {
	l = !is.na(x)
	if(sum(l) >= 2) {
		oe1 = try(x <- suppressWarnings(predict(locfit(x[l] ~ lp(seq_along(x)[l], nn = 0.1, h = 0.8)), seq_along(x))), silent = TRUE)
		if(inherits(oe1, "try-error")) {
			oe2 = try(x <-  suppressWarnings(predict(loess(x[l] ~ seq_along(x)[l], control = loess.control(surface = "direct")), seq_along(x))))

			if(inherits(oe2, "try-error")) {
				stop("error when doing locfit or loess smoothing")
			} else {
				return(x)
			}
		} else {
			return(x)
		}
	} else {
		stop("Too few data points.")
	}
	return(x)
}
