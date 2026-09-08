pub mod core;
pub mod g2p;
pub mod lang;
pub mod punc;

#[cfg(feature = "python")]
mod python {
    use pyo3::prelude::*;
    use pyo3::wrap_pyfunction;

    use crate::g2p;

    #[pyfunction]
    fn punc_norm(text: &str) -> String {
        crate::punc::apply_punc_norm(text)
    }

    #[pyclass]
    struct G2P {
        engine: g2p::G2PEngine,
        thai: std::sync::OnceLock<crate::lang::th::Thai>,
    }

    #[pymethods]
    impl G2P {
        #[new]
        fn new(dict_path: &str) -> PyResult<Self> {
            let engine = g2p::G2PEngine::new(dict_path)
                .map_err(|e| {
                    pyo3::exceptions::PyIOError::new_err(
                        e.to_string(),
                    )
                })?;

            Ok(G2P {
                engine,
                thai: std::sync::OnceLock::new(),
            })
        }

        #[pyo3(signature = (text, punc_norm=false))]
        fn phonemize(
            &self,
            text: &str,
            punc_norm: bool,
        ) -> PyResult<String> {
            let input = if punc_norm {
                crate::punc::apply_punc_norm(text)
            } else {
                text.to_string()
            };

            Ok(self.engine.phonemize(&input))
        }
    }

    #[pymodule]
    fn sea_g2p_rs(
        m: &Bound<'_, PyModule>,
    ) -> PyResult<()> {
        m.add_class::<G2P>()?;
        m.add_class::<crate::lang::vi::Normalizer>()?;
        m.add_function(
            wrap_pyfunction!(punc_norm, m)?,
        )?;

        Ok(())
    }
}