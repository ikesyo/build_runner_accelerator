import 'package:json_annotation/json_annotation.dart';

part 'model_263.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model263 {
  const Model263({required this.id, required this.value});

  final int id;
  final String value;

  factory Model263.fromJson(Map<String, dynamic> json) =>
      _$Model263FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model263ToJson(this);
}
