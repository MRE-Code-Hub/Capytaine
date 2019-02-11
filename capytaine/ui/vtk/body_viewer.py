
import vtk

from capytaine.ui.vtk.mesh_viewer import MeshViewer


class FloatingBodyViewer(MeshViewer):

    def __init__(self):
        super().__init__()
        self.dofs_data = {}

    def add_body(self, body, **kwargs):
        self.add_mesh(body.mesh, **kwargs)

        for dof in body.dofs:
            vtk_data_array = vtk.vtkFloatArray()
            vtk_data_array.SetNumberOfComponents(3)
            vtk_data_array.SetNumberOfTuples(body.mesh.nb_faces)
            for i, vector in enumerate(body.dofs[dof]):
                vtk_data_array.SetTuple3(i, *vector)
            self.dofs_data[dof] = vtk_data_array
            # vtk_polydata.GetCellData().SetVectors(vtk_data_array)