import 'package:json_annotation/json_annotation.dart';

part 'model_420.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model420 {
  const Model420({required this.id, required this.value});

  final int id;
  final String value;

  factory Model420.fromJson(Map<String, dynamic> json) =>
      _$Model420FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model420ToJson(this);
}
