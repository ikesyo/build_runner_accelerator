import 'package:json_annotation/json_annotation.dart';

part 'model_008.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model008 {
  const Model008({required this.id, required this.value});

  final int id;
  final String value;

  factory Model008.fromJson(Map<String, dynamic> json) =>
      _$Model008FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model008ToJson(this);
}
