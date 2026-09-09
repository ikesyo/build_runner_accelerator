import 'package:json_annotation/json_annotation.dart';

part 'model_338.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model338 {
  const Model338({required this.id, required this.value});

  final int id;
  final String value;

  factory Model338.fromJson(Map<String, dynamic> json) =>
      _$Model338FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model338ToJson(this);
}
