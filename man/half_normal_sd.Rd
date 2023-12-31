% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/half_normal_kernel.R
\name{half_normal_sd}
\alias{half_normal_sd}
\title{Return the \code{sd} for Half-normal distribution}
\usage{
half_normal_sd(mean)
}
\arguments{
\item{mean}{Target mean}
}
\value{
The standard deviation for \code{dnorm}/\code{rnorm}, etc. to
match the desired mean of a half-normal distribution.
}
\description{
To represent the half-normal distribution using
\code{dnorm}, the \code{sd} has to be adjusted, to yield
a certain mean.
}
