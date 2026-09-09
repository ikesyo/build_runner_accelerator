import 'package:json_annotation/json_annotation.dart';

part 'model_173.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model173 {
  const Model173({required this.id, required this.value});

  final int id;
  final String value;

  factory Model173.fromJson(Map<String, dynamic> json) =>
      _$Model173FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model173ToJson(this);
}
