import 'package:json_annotation/json_annotation.dart';

part 'model_481.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model481 {
  const Model481({required this.id, required this.value});

  final int id;
  final String value;

  factory Model481.fromJson(Map<String, dynamic> json) =>
      _$Model481FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model481ToJson(this);
}
