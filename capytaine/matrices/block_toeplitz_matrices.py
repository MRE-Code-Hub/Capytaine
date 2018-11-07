#!/usr/bin/env python
# coding: utf-8

import logging
from typing import Tuple, List

import numpy as np

from capytaine.matrices.block_matrices import BlockMatrix

LOG = logging.getLogger(__name__)

################################################################################
#                       Block symmetric Toeplitz matrix                        #
################################################################################

class BlockSymmetricToeplitzMatrix(BlockMatrix):
    """A (2D) block symmetric Toeplitz matrix, stored as a list of blocks.

    Stored in the backend as a 1×N array of arrays.
    """

    # ACCESSING DATA

    def _index_grid(self) -> np.ndarray:
        """Helper function to find the positions at which the blocks appears in the full matrix.

        Example of output::

            [[1, 2, 3, 4, 5],
             [2, 1, 2, 3, 4],
             [3, 2, 1, 2, 3],
             [4, 3, 2, 1, 2],
             [5, 4, 3, 2, 1]]
        """
        n = self.nb_blocks[0]
        return np.array([[abs(i-j) for i in range(n)] for j in range(n)])

    @property
    def all_blocks(self) -> np.ndarray:
        """The matrix of matrices as if the block Toeplitz structure was not used."""
        return np.array([[block for block in self.first_block_line[indices]] for indices in self._index_grid()])

    @property
    def nb_blocks(self) -> Tuple[int, int]:
        """The number of blocks in each direction."""
        return self._stored_nb_blocks[1], self._stored_nb_blocks[1]

    @property
    def block_shapes(self):
        """The shapes of the blocks composing the block matrix.
        Actually, they should be all the same."""
        return ([self._stored_block_shapes[0][0]]*self.nb_blocks[0],
                self._stored_block_shapes[1])

    @property
    def block_shape(self):
        """The shape of any block."""
        return self._stored_block_shapes[0][0], self._stored_block_shapes[1][0]  # Shape of first stored block

    @property
    def shape(self):
        """The total size of the matrix."""
        return self._stored_block_shapes[0][0]*self.nb_blocks[0], self._stored_block_shapes[1][0]*self.nb_blocks[1]

    @property
    def first_block_line(self):
        """The blocks on the first line of blocks in the matrix."""
        return self._stored_blocks[0, :]

    def _check_dimension(self) -> None:
        block_shape = self._stored_blocks[0, 0].shape
        for block in self._stored_blocks[0, 1:]:
            assert block.shape == block_shape  # All blocks have same shape

    def _positions_of_index(self, k: int) -> List[Tuple[int, int]]:
        """The block indices at which the block k from the first line can also be found."""
        n = self.nb_blocks[0]
        return [(i, j) for i in range(n) for j in range(n) if abs(i-j) == k]

    # DISPLAYING DATA

    def _patches(self, global_frame: Tuple[int, int]):
        from matplotlib.patches import Rectangle
        patches = []

        # Recursively plot the blocks on the first line.
        for k, block in enumerate(self.first_block_line):
            block_position_in_global_frame = (global_frame[0] + k*self.block_shape[1],
                                              global_frame[1])
            if isinstance(block, BlockMatrix):
                patches_of_this_block = block._patches(block_position_in_global_frame)
            elif isinstance(block, np.ndarray):
                patches_of_this_block = [Rectangle(block_position_in_global_frame,
                                                   self.block_shape[1], self.block_shape[0],
                                                   edgecolor='k', facecolor=next(self.display_color))]
            else:
                raise AttributeError()

            # Copy the patches to fill the rest of the matrix.
            for i, j in self._positions_of_index(k)[1:]:
                for patch in patches_of_this_block:
                    local_shift = np.array(patch.get_xy()) + np.array(((j-k)*self.block_shape[1], i*self.block_shape[0]))
                    patches.append(Rectangle(local_shift, patch.get_width(), patch.get_height(),
                                             facecolor=patch.get_facecolor(), alpha=0.5))
            patches.extend(patches_of_this_block)

        return patches

    # TRANSFORMING DATA

    def __matmul__(self, other):
        if isinstance(other, np.ndarray) and other.ndim == 1 and self.shape[1] == other.shape[0]:
            LOG.debug(f"Multiplication of %s with a vector.", self)
            A = EvenBlockSymmetricCirculantMatrix(self._stored_blocks,
                                                  _stored_block_shapes=self._stored_block_shapes,
                                                  check_dim=False)
            b = np.concatenate([other, np.zeros(A.shape[1] - self.shape[1])])
            return (A @ b)[:self.shape[0]]

        else:
            return NotImplemented
    @property
    def T(self):
        """Transpose the matrix."""
        transposed_blocks = np.array([[block.T for block in self._stored_blocks[0, :]]])
        return self.__class__(transposed_blocks)


###########################################################################
#                    Block symmetric circulant matrix                     #
###########################################################################

class AbstractBlockSymmetricCirculantMatrix(BlockSymmetricToeplitzMatrix):
    """Should not be instantiated. Just here to factor some common code between the two classes below."""

    @property
    def nb_blocks(self):
        return self._nb_blocks, self._nb_blocks

    @property
    def block_shapes(self):
        return ([self._stored_block_shapes[0][0]]*self.nb_blocks[0],
                [self._stored_block_shapes[1][0]]*self.nb_blocks[1])

    def _index_grid(self):
        line = self._baseline_grid()
        grid = [line]
        for i in range(1, self.nb_blocks[0]):
            grid.append(line[-i:] + line[:-i])
        return np.array(grid)

    def _positions_of_index(self, k):
        n = self.nb_blocks[0]
        grid = self._index_grid()
        return [(i, j) for i in range(n) for j in range(n) if grid[i, j] == k]

    @property
    def first_block_line(self):
        return self._stored_blocks[0, self._baseline_grid()]

    def __matmul__(self, other):
        if isinstance(other, np.ndarray) and other.ndim == 1 and self.shape[1] == other.shape[0]:
            LOG.debug(f"Multiplication of %s with a vector.", self)
            AA = np.array([block.full_matrix() if not isinstance(block, np.ndarray) else block
                           for block in self.first_block_line])
            AAt = np.fft.fft(AA, axis=0)
            bt = np.fft.fft(np.reshape(other, AAt.shape[:2] + (1,)), axis=0)
            yt = AAt @ bt
            y = np.fft.ifft(yt, axis=0).reshape(self.shape[0])
            return np.asarray(y, dtype=other.dtype)

        else:
            return NotImplemented


class EvenBlockSymmetricCirculantMatrix(AbstractBlockSymmetricCirculantMatrix):
    """A block symmetric circulant matrix, with an even number of blocks.

    Examples::

        ABCB
        BABC
        CBAB
        BCBA

        ABCDCB
        BABCDB
        CBABCD
        DCBABC
        CDCBAB
        BCDCBA
    """

    def __init__(self, blocks, **kwargs):
        super().__init__(blocks, **kwargs)
        self._nb_blocks = (self._stored_nb_blocks[1] - 1) * 2

    # ACCESSING DATA

    def _baseline_grid(self):
        blocks_indices = list(range(len(self._stored_blocks[0, :])))
        return blocks_indices[:-1] + blocks_indices[1:][::-1]


class OddBlockSymmetricCirculantMatrix(AbstractBlockSymmetricCirculantMatrix):
    """A block symmetric circulant matrix, with an odd number of blocks.

    Examples::

        ABCCB
        BABCC
        CBABC
        CCBAB
        BCCBA

        ABCDDCB
        BABCDDB
        CBABCDD
        DCBABCD
        DDCBABC
        CDDCBAB
        BCDDCBA
    """

    def __init__(self, blocks, **kwargs):
        super().__init__(blocks, **kwargs)
        self._nb_blocks = self._stored_nb_blocks[1] * 2 - 1

    # ACCESSING DATA

    def _baseline_grid(self):
        blocks_indices = list(range(len(self._stored_blocks[0, :])))
        return blocks_indices[:] + blocks_indices[1:][::-1]

