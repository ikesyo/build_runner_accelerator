import 'package:json_annotation/json_annotation.dart';

part 'model_323.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model323 {
  const Model323({required this.id, required this.value});

  final int id;
  final String value;

  factory Model323.fromJson(Map<String, dynamic> json) =>
      _$Model323FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model323ToJson(this);
}
