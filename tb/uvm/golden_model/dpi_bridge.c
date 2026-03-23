/*
 * dpi_bridge.c — DPI-C bridge to Python golden model
 *
 * Provides SystemVerilog DPI-C import functions that call the shared
 * Python golden model (golden_model.py) for bit-accurate reference
 * computation. This ensures UVM and cocotb use the same source of truth.
 *
 * Functions:
 *   dpi_golden_init()       — Initialize Python interpreter and load model
 *   dpi_golden_inference()  — Compute dot product with bfloat16/fp32 semantics
 *   dpi_golden_extract_features() — Compute feature vector from parsed fields
 *   dpi_golden_cleanup()    — Finalize Python interpreter
 */

#include <Python.h>
#include <svdpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static PyObject *p_module = NULL;
static PyObject *p_model_inst = NULL;
static int initialized = 0;

/* ----------------------------------------------------------------
 * DPI export: Initialize Python and load the golden model
 * ---------------------------------------------------------------- */
int dpi_golden_init(const char *model_path)
{
    PyObject *p_name, *p_class, *p_args;
    char dir_buf[1024];
    char *last_slash;

    if (initialized)
        return 0;

    Py_Initialize();
    if (!Py_IsInitialized())
    {
        fprintf(stderr, "DPI-C: Failed to initialize Python\n");
        return -1;
    }

    /* Add the golden model directory to sys.path */
    strncpy(dir_buf, model_path, sizeof(dir_buf) - 1);
    dir_buf[sizeof(dir_buf) - 1] = '\0';
    last_slash = strrchr(dir_buf, '/');
    if (last_slash)
        *last_slash = '\0';

    PyObject *sys_path = PySys_GetObject("path");
    PyObject *py_dir = PyUnicode_FromString(dir_buf);
    PyList_Append(sys_path, py_dir);
    Py_DECREF(py_dir);

    /* Import the golden_model module */
    p_name = PyUnicode_FromString("golden_model");
    p_module = PyImport_Import(p_name);
    Py_DECREF(p_name);

    if (!p_module)
    {
        PyErr_Print();
        fprintf(stderr, "DPI-C: Failed to import golden_model from %s\n", dir_buf);
        return -1;
    }

    /* Create GoldenModel instance */
    p_class = PyObject_GetAttrString(p_module, "GoldenModel");
    if (!p_class || !PyCallable_Check(p_class))
    {
        PyErr_Print();
        fprintf(stderr, "DPI-C: GoldenModel class not found\n");
        Py_XDECREF(p_class);
        return -1;
    }

    p_args = PyTuple_New(0);
    p_model_inst = PyObject_CallObject(p_class, p_args);
    Py_DECREF(p_args);
    Py_DECREF(p_class);

    if (!p_model_inst)
    {
        PyErr_Print();
        fprintf(stderr, "DPI-C: Failed to create GoldenModel instance\n");
        return -1;
    }

    initialized = 1;
    return 0;
}

/* ----------------------------------------------------------------
 * DPI export: Compute inference result
 *
 * features[] and weights[] are arrays of bfloat16 bit patterns (16-bit).
 * Returns float32 result via *result pointer.
 * ---------------------------------------------------------------- */
int dpi_golden_inference(
    const unsigned short *features, int num_features,
    const unsigned short *weights, int num_weights,
    float *result)
{
    PyObject *p_method, *p_feat_list, *p_wgt_list, *p_result;
    int i;

    if (!initialized || !p_model_inst)
        return -1;
    if (num_features != num_weights)
        return -1;

    /* Build Python lists of float values from bfloat16 bit patterns */
    p_feat_list = PyList_New(num_features);
    p_wgt_list = PyList_New(num_weights);

    for (i = 0; i < num_features; i++)
    {
        /* Convert bfloat16 to float: shift left 16 bits to get float32 bits */
        unsigned int fp32_bits = (unsigned int)features[i] << 16;
        float f;
        memcpy(&f, &fp32_bits, sizeof(float));
        PyList_SetItem(p_feat_list, i, PyFloat_FromDouble((double)f));
    }

    for (i = 0; i < num_weights; i++)
    {
        unsigned int fp32_bits = (unsigned int)weights[i] << 16;
        float f;
        memcpy(&f, &fp32_bits, sizeof(float));
        PyList_SetItem(p_wgt_list, i, PyFloat_FromDouble((double)f));
    }

    /* Call model.inference(features, weights) */
    p_method = PyObject_GetAttrString(p_model_inst, "inference");
    if (!p_method)
    {
        PyErr_Print();
        Py_DECREF(p_feat_list);
        Py_DECREF(p_wgt_list);
        return -1;
    }

    /* Import numpy for array conversion */
    PyObject *np_mod = PyImport_ImportModule("numpy");
    if (!np_mod)
    {
        PyErr_Print();
        Py_DECREF(p_method);
        Py_DECREF(p_feat_list);
        Py_DECREF(p_wgt_list);
        return -1;
    }

    PyObject *np_array = PyObject_GetAttrString(np_mod, "array");
    PyObject *np_f32 = PyObject_GetAttrString(np_mod, "float32");

    /* Convert lists to numpy arrays with dtype=float32 */
    PyObject *feat_args = PyTuple_Pack(1, p_feat_list);
    PyObject *feat_kw = PyDict_New();
    PyDict_SetItemString(feat_kw, "dtype", np_f32);
    PyObject *feat_arr = PyObject_Call(np_array, feat_args, feat_kw);

    PyObject *wgt_args = PyTuple_Pack(1, p_wgt_list);
    PyObject *wgt_kw = PyDict_New();
    PyDict_SetItemString(wgt_kw, "dtype", np_f32);
    PyObject *wgt_arr = PyObject_Call(np_array, wgt_args, wgt_kw);

    /* Call inference */
    PyObject *call_args = PyTuple_Pack(2, feat_arr, wgt_arr);
    p_result = PyObject_CallObject(p_method, call_args);

    if (!p_result)
    {
        PyErr_Print();
        *result = 0.0f;
    }
    else
    {
        *result = (float)PyFloat_AsDouble(p_result);
        Py_DECREF(p_result);
    }

    Py_DECREF(call_args);
    Py_DECREF(wgt_arr);
    Py_DECREF(wgt_kw);
    Py_DECREF(wgt_args);
    Py_DECREF(feat_arr);
    Py_DECREF(feat_kw);
    Py_DECREF(feat_args);
    Py_DECREF(np_f32);
    Py_DECREF(np_array);
    Py_DECREF(np_mod);
    Py_DECREF(p_method);
    Py_DECREF(p_feat_list);
    Py_DECREF(p_wgt_list);

    return 0;
}

/* ----------------------------------------------------------------
 * DPI export: Extract features from parsed ITCH fields
 *
 * Returns bfloat16 feature vector via features_out[] (4 elements).
 * ---------------------------------------------------------------- */
int dpi_golden_extract_features(
    unsigned int price,
    unsigned long long order_ref,
    int side,
    unsigned short *features_out,
    int num_features)
{
    PyObject *p_method, *p_args, *p_result;
    int i;

    if (!initialized || !p_model_inst)
        return -1;

    p_method = PyObject_GetAttrString(p_model_inst, "extract_features");
    if (!p_method)
    {
        PyErr_Print();
        return -1;
    }

    p_args = PyTuple_Pack(3,
                          PyLong_FromUnsignedLong(price),
                          PyLong_FromUnsignedLongLong(order_ref),
                          PyLong_FromLong(side));
    p_result = PyObject_CallObject(p_method, p_args);
    Py_DECREF(p_args);
    Py_DECREF(p_method);

    if (!p_result)
    {
        PyErr_Print();
        return -1;
    }

    /* Import float_to_bfloat16 function */
    PyObject *bf16_func = PyObject_GetAttrString(p_module, "float_to_bfloat16");

    /* Extract float values and convert to bfloat16 */
    for (i = 0; i < num_features && i < (int)PyObject_Length(p_result); i++)
    {
        PyObject *item = PyObject_GetItem(p_result, PyLong_FromLong(i));
        double val = PyFloat_AsDouble(item);

        /* Convert to bfloat16 via golden model function */
        PyObject *bf16_args = PyTuple_Pack(1, PyFloat_FromDouble(val));
        PyObject *bf16_val = PyObject_CallObject(bf16_func, bf16_args);
        features_out[i] = (unsigned short)PyLong_AsLong(bf16_val);

        Py_DECREF(bf16_val);
        Py_DECREF(bf16_args);
        Py_DECREF(item);
    }

    Py_DECREF(bf16_func);
    Py_DECREF(p_result);
    return 0;
}

/* ----------------------------------------------------------------
 * DPI export: Cleanup Python interpreter
 * ---------------------------------------------------------------- */
void dpi_golden_cleanup(void)
{
    Py_XDECREF(p_model_inst);
    Py_XDECREF(p_module);
    p_model_inst = NULL;
    p_module = NULL;
    initialized = 0;

    if (Py_IsInitialized())
        Py_Finalize();
}
