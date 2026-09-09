import 'package:json_annotation/json_annotation.dart';

part 'model_195.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model195 {
  const Model195({required this.id, required this.value});

  final int id;
  final String value;

  factory Model195.fromJson(Map<String, dynamic> json) =>
      _$Model195FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model195ToJson(this);
}
