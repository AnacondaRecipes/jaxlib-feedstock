# JAX 0.6.0 Build Strategy - PIVOT FROM 0.6.1

## New Strategy: Build jaxlib 0.6.0 Instead

**Rationale:**
- JAX 0.6.0 is available in conda-forge (proven to build successfully)
- We can learn from conda-forge's working recipe
- Much more realistic target than fighting unknown 0.6.1 issues

## Tasks for jaxlib 0.6.0 Build

1. **Update version** from 0.6.1 to 0.6.0 in recipe files
2. **Get correct source URL and hash** for jaxlib 0.6.0
3. **Update dependencies** to match conda-forge 0.6.0 requirements
4. **Review conda-forge recipe** for 0.6.0 to see their approach
5. **Test build** with known working configuration

## Previous Build Issues (for reference)
- JAX 0.6.1 has unresolved clang header dependency tracking issues
- 26+ failed build attempts with various strategies
- Even conda-forge hasn't successfully built 0.6.1 yet
