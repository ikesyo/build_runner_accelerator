import 'package:json_annotation/json_annotation.dart';

part 'model_057.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model057 {
  const Model057({required this.id, required this.value});

  final int id;
  final String value;

  factory Model057.fromJson(Map<String, dynamic> json) =>
      _$Model057FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model057ToJson(this);
}
