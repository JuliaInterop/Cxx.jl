using CXX

const qtlibdir = "/Users/kfischer/Projects/qt-everywhere-opensource-src-5.3.1/qtbase/~/usr/lib/"
const QtCore = joinpath(qtlibdir,"QtCore.framework/")
const QtWidgets = joinpath(qtlibdir,"QtWidgets.framework/")

addHeaderDir(qtlibdir; isFramework = true, kind = C_System)

dlopen(joinpath(QtCore,"QtCore_debug"))
addHeaderDir(joinpath(QtCore,"Headers"))

dlopen(joinpath(QtWidgets,"QtWidgets_debug"))
addHeaderDir(joinpath(QtWidgets,"Headers"))

cxxinclude("QApplication")
cxxinclude("QMessageBox")


x = Ptr{Uint8}[pointer("julia"),C_NULL]
app = @cxx QApplication(int32(0),pointer(x))

@cxx QMessageBox::about(cast(C_NULL,pcpp"QWidget"), pointer("Hello World"), pointer("This is a QMessageBox!"))

@cxx app->exec()