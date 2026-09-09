import 'package:json_annotation/json_annotation.dart';

part 'model_354.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model354 {
  const Model354({required this.id, required this.value});

  final int id;
  final String value;

  factory Model354.fromJson(Map<String, dynamic> json) =>
      _$Model354FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model354ToJson(this);
}
